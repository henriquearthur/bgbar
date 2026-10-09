import Foundation

/// Agentes Claude de uma máquina remota: espelha por ssh, num cache local, os transcripts
/// de `~/.claude/projects` das sessões recentes e roda o mesmo `ClaudeAgentsScanner` sobre
/// o espelho. Assim estados, árvore e painel de log são os mesmos da máquina local.
///
/// O espelho é incremental: os `.jsonl` só crescem, então cada rodada busca apenas os bytes
/// novos (sempre linhas completas, para o tamanho local ser o offset remoto). Do transcript
/// principal vem só o começo (de onde sai o cwd); a atividade vem do mtime, que é copiado.
actor RemoteClaudeMirror {
    let host: String
    /// Raiz do espelho (equivale a `~/.claude/projects`).
    let root: URL
    private let scanner: ClaudeAgentsScanner
    private let fm = FileManager.default

    /// Bytes por arquivo por rodada (o que passar disso vem na próxima).
    static let perFileCap = 8 << 20
    /// Começo do transcript principal: o bastante para achar o cwd.
    static let headBytes = 256 << 10
    static let maxFilesPerRound = 8

    init(host: String, root: URL? = nil) {
        self.host = host
        self.root = root ?? Self.defaultRoot(host: host)
        scanner = ClaudeAgentsScanner(root: self.root)
        scanner.host = host
    }

    static func defaultRoot(host: String) -> URL {
        let safe = String(host.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("BGBar/remote-claude/\(safe)/projects")
    }

    // MARK: Listagem

    /// Sessões com transcript principal ou pasta `subagents/` alterados na janela do scanner
    /// (2 h): `<tipo>\t<bytes>\t<mtime>\t<caminho>`, com tipo m (principal), f (arquivo de
    /// subagente) ou d (a pasta `subagents`).
    static let listScript = #"""
        cd "$HOME/.claude/projects" 2>/dev/null || { echo '@@bgbar:end'; exit 0; }
        echo '@@bgbar:files'
        {
          find . -mindepth 2 -maxdepth 2 -name '*.jsonl' -mmin -120 | sed 's/\.jsonl$//'
          find . -mindepth 3 -maxdepth 3 -name subagents -mmin -120 | sed 's,/subagents$,,'
        } | sort -u | while IFS= read -r s; do
          find "$s.jsonl" -maxdepth 0 -printf 'm\t%s\t%T@\t%p\n' 2>/dev/null
          [ -d "$s/subagents" ] && find "$s/subagents" -maxdepth 1 \( -name 'agent-*' -o -name subagents \) -printf '%y\t%s\t%T@\t%p\n'
        done
        echo '@@bgbar:end'

        """#

    struct Entry: Equatable {
        enum Kind: Equatable { case main, file, dir }
        var kind: Kind
        var size: UInt64
        var mtime: Date
        /// Caminho remoto relativo a `~/.claude/projects` (já validado).
        var path: String
        var local: URL
    }

    /// nil se a listagem veio incompleta. Caminhos fora do formato esperado são descartados:
    /// eles viram caminhos de escrita no cache, então nada de `..` nem níveis a mais.
    static func parseListing(_ out: String, root: URL) -> [Entry]? {
        let s = Remote.sections(out)
        guard s["end"] != nil else { return nil }
        return (s["files"] ?? "").split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard cols.count == 4, let size = UInt64(cols[1]), let mtime = Double(cols[2]) else { return nil }
            let comps = cols[3].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard comps.first == ".", comps.dropFirst().allSatisfy({ c in
                !c.isEmpty && c != "." && c != ".." && !c.unicodeScalars.contains { $0.value < 0x20 }
            }) else { return nil }
            let kind: Entry.Kind
            switch (cols[0], comps.count) {
            case ("m", 3) where comps[2].hasSuffix(".jsonl"): kind = .main
            case ("d", 4) where comps[3] == "subagents": kind = .dir
            case ("f", 5) where comps[3] == "subagents" && comps[4].hasPrefix("agent-"): kind = .file
            default: return nil
            }
            let local = comps.dropFirst().reduce(root) { $0.appendingPathComponent($1) }
            return Entry(kind: kind, size: size, mtime: Date(timeIntervalSince1970: mtime),
                         path: String(cols[3]), local: local)
        }
    }

    // MARK: Busca

    enum Fetch: Equatable {
        /// Começo do transcript principal (uma vez só).
        case head
        /// Bytes novos de um `.jsonl`, a partir do tamanho local.
        case append(from: UInt64)
        /// Arquivo pequeno inteiro (`.meta.json`).
        case whole
    }

    func plan(_ e: Entry) -> Fetch? {
        let attrs = try? fm.attributesOfItem(atPath: e.local.path)
        let localSize = (attrs?[.size] as? NSNumber)?.uint64Value
        switch e.kind {
        case .dir: return nil
        case .main: return attrs == nil ? .head : nil
        case .file where e.path.hasSuffix(".jsonl"):
            guard let localSize else { return e.size > 0 ? .append(from: 0) : nil }
            if localSize > e.size { // arquivo remoto foi substituído
                try? fm.removeItem(at: e.local)
                return .append(from: 0)
            }
            return localSize < e.size ? .append(from: localSize) : nil
        case .file:
            guard let localSize, let mt = attrs?[.modificationDate] as? Date else { return .whole }
            return localSize != e.size || abs(mt.timeIntervalSince(e.mtime)) > 0.01 ? .whole : nil
        }
    }

    static let marker = "\n@@bgbar-file:"

    /// Cada arquivo vem depois de uma linha `@@bgbar-file:<índice>`; `@@bgbar-file:end` fecha.
    static func fetchScript(_ batch: [(entry: Entry, fetch: Fetch)]) -> String {
        var script = "cd \"$HOME/.claude/projects\" || exit 0\n"
        for (i, item) in batch.enumerated() {
            let path = Remote.quote(item.entry.path)
            script += "printf '\\n@@bgbar-file:\(i)\\n'\n"
            switch item.fetch {
            case .head: script += "head -c \(headBytes) \(path)\n"
            case .append(let from): script += "tail -c +\(from + 1) \(path) | head -c \(perFileCap)\n"
            case .whole: script += "head -c 1048576 \(path)\n"
            }
        }
        return script + "printf '\\n@@bgbar-file:end\\n'\n"
    }

    /// Conteúdo por índice. O último trecho nunca conta: ou é o `end`, ou veio truncado.
    static func parseFetched(_ out: String) -> [Int: String] {
        var bodies: [Int: String] = [:]
        for part in out.components(separatedBy: marker).dropFirst().dropLast() {
            guard let nl = part.firstIndex(of: "\n"), let idx = Int(part[..<nl]) else { continue }
            bodies[idx] = String(part[part.index(after: nl)...])
        }
        return bodies
    }

    /// Só as linhas completas (até o último "\n", inclusive).
    static func completeLines(_ body: String) -> Substring {
        guard let nl = body.lastIndex(of: "\n") else { return "" }
        return body[...nl]
    }

    /// Grava o que veio. Devolve true se algum arquivo bateu no teto (há mais para buscar).
    private func apply(_ bodies: [Int: String], _ batch: [(entry: Entry, fetch: Fetch)]) -> Bool {
        var more = false
        for (i, item) in batch.enumerated() {
            guard let body = bodies[i] else { continue }
            let url = item.entry.local
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch item.fetch {
            case .head:
                let lines = Self.completeLines(body)
                try? Data((lines.isEmpty ? Substring(body) : lines).utf8).write(to: url, options: .atomic)
            case .whole:
                try? Data(body.utf8).write(to: url, options: .atomic)
            case .append:
                if body.utf8.count >= Self.perFileCap - 4 { more = true }
                let data = Data(Self.completeLines(body).utf8)
                guard !data.isEmpty else { continue }
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                guard let h = try? FileHandle(forWritingTo: url) else { continue }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            }
        }
        return more
    }

    /// Copia os mtimes remotos (o scanner decide estados por eles) e apaga do espelho o que
    /// saiu da listagem. Pastas por último: gravar um arquivo mexe no mtime da pasta.
    private func stampAndPrune(_ entries: [Entry]) {
        var keep = Set<String>()
        for e in entries.sorted(by: { ($0.kind == .dir ? 1 : 0) < ($1.kind == .dir ? 1 : 0) }) {
            if e.kind == .dir { try? fm.createDirectory(at: e.local, withIntermediateDirectories: true) }
            try? fm.setAttributes([.modificationDate: e.mtime], ofItemAtPath: e.local.path)
            var url = e.local.standardizedFileURL
            while url.path.count > root.standardizedFileURL.path.count {
                keep.insert(url.path)
                url.deleteLastPathComponent()
            }
        }
        let all = (fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for url in all.sorted(by: { $0.path.count > $1.path.count }) where !keep.contains(url.standardizedFileURL.path) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Rodada

    /// Uma rodada: lista, busca o que mudou e varre o espelho. `backlog` = ainda há o que
    /// buscar (rode de novo sem esperar). Com o host fora do ar, o espelho antigo continua
    /// sendo varrido: as sessões envelhecem e saem da janela sozinhas.
    func sync() async -> (sessions: [ClaudeSession], backlog: Bool) {
        var backlog = false
        let listing = await Remote.run(host, Self.listScript, timeout: 15)
        if let entries = Self.parseListing(listing.out, root: root) {
            let wanted = entries.compactMap { e in plan(e).map { (entry: e, fetch: $0) } }
            let batch = Array(wanted.prefix(Self.maxFilesPerRound))
            backlog = wanted.count > batch.count
            if !batch.isEmpty {
                let r = await Remote.run(host, Self.fetchScript(batch), timeout: 45)
                if apply(Self.parseFetched(r.out), batch) { backlog = true }
            }
            stampAndPrune(entries)
        }
        return (scanner.scan(), backlog)
    }
}
