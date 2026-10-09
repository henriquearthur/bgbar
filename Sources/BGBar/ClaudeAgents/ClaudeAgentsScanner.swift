import Foundation

/// Varre ~/.claude/projects e monta as sessões ativas com a árvore de subagentes.
/// Não é thread-safe: use sempre da mesma fila serial (o store faz isso).
final class ClaudeAgentsScanner {
    struct Thresholds {
        /// jsonl escrito há menos que isso => rodando.
        var recentWrite: TimeInterval = 90
        /// Sem fechamento (tool pendente / aguardando modelo) e sem escrita há mais que isso => falhou (abandonado).
        var abandoned: TimeInterval = 20 * 60
        /// Janela de sessões exibidas.
        var window: TimeInterval = 2 * 3600
        /// Sessão sem subagentes só aparece enquanto a conversa principal está ativa.
        var mainOnly: TimeInterval = 15 * 60
    }

    struct Meta: Equatable {
        var agentType: String
        var description: String
        var parentAgentId: String?
        var spawnDepth: Int?
    }

    let root: URL
    var thresholds = Thresholds()
    /// Máquina remota de onde `root` foi espelhado (carimbada nas sessões); nil = local.
    var host: String?

    private var readers: [String: ClaudeTranscriptReader] = [:]
    private var metas: [String: (mtime: Date, meta: Meta)] = [:]
    private var sessionCwd: [String: String] = [:]
    private let fm = FileManager.default

    init(root: URL = ClaudeAgentsScanner.defaultRoot) { self.root = root }

    static var defaultRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    // MARK: - Varredura

    func scan(now: Date = Date()) -> [ClaudeSession] {
        var out: [ClaudeSession] = []
        var seenTranscripts = Set<String>()
        var seenMetas = Set<String>()
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
        for project in projects where isDir(project) {
            for (sessionId, mainURL, subDir) in candidateSessions(in: project, now: now) {
                var transcripts = Set<String>(), metaPaths = Set<String>()
                if let s = buildSession(id: sessionId, project: project, mainURL: mainURL, subDir: subDir,
                                        now: now, seenTranscripts: &transcripts, seenMetas: &metaPaths) {
                    out.append(s)
                    // Só sessões exibidas seguram cache; as que saíram da janela são liberadas abaixo.
                    seenTranscripts.formUnion(transcripts)
                    seenMetas.formUnion(metaPaths)
                }
            }
        }
        // Libera caches (leitores com offset, metas, cwd) de arquivos/sessões que saíram da janela ou sumiram.
        readers = readers.filter { seenTranscripts.contains($0.key) }
        metas = metas.filter { seenMetas.contains($0.key) }
        let liveSessions = Set(out.map(\.id))
        sessionCwd = sessionCwd.filter { liveSessions.contains($0.key) }
        return out.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Sessões com pasta subagents/ cujo transcript principal ou pasta de subagentes mudou dentro da janela,
    /// mais as que só têm a conversa principal e foram escritas há pouco (`mainOnly`).
    private func candidateSessions(in project: URL, now: Date) -> [(String, URL, URL?)] {
        guard let entries = try? fm.contentsOfDirectory(atPath: project.path) else { return [] }
        var result: [(String, URL, URL?)] = []
        for name in entries where !name.contains(".") {
            let sessionDir = project.appendingPathComponent(name)
            let subDir = sessionDir.appendingPathComponent("subagents")
            guard isDir(subDir) else { continue }
            let mainURL = project.appendingPathComponent(name + ".jsonl")
            let newest = [mtime(mainURL), mtime(subDir)].compactMap { $0 }.max()
            guard let newest, now.timeIntervalSince(newest) <= thresholds.window else { continue }
            result.append((name, mainURL, subDir))
        }
        for name in entries where name.hasSuffix(".jsonl") {
            let id = String(name.dropLast(".jsonl".count))
            let mainURL = project.appendingPathComponent(name)
            guard !isDir(project.appendingPathComponent(id).appendingPathComponent("subagents")),
                  let m = mtime(mainURL), now.timeIntervalSince(m) <= thresholds.mainOnly else { continue }
            result.append((id, mainURL, nil))
        }
        return result
    }

    private func buildSession(id: String, project: URL, mainURL: URL, subDir: URL?, now: Date,
                              seenTranscripts: inout Set<String>, seenMetas: inout Set<String>) -> ClaudeSession? {
        let files = subDir.flatMap { try? fm.contentsOfDirectory(atPath: $0.path) } ?? []
        struct Flat { var meta: Meta; var node: ClaudeAgentNode; var summary: ClaudeTranscriptSummary; var mtime: Date }
        var flat: [String: Flat] = [:]

        for f in files where f.hasPrefix("agent-") && f.hasSuffix(".meta.json") {
            guard let subDir else { break }
            let agentId = String(f.dropFirst("agent-".count).dropLast(".meta.json".count))
            let metaURL = subDir.appendingPathComponent(f)
            let jsonl = subDir.appendingPathComponent("agent-\(agentId).jsonl")
            guard let meta = loadMeta(metaURL) else { continue }
            seenMetas.insert(metaURL.path)
            let mt = mtime(jsonl) ?? mtime(metaURL) ?? now
            let reader = readers[jsonl.path] ?? ClaudeTranscriptReader(url: jsonl)
            readers[jsonl.path] = reader
            seenTranscripts.insert(jsonl.path)
            reader.update()
            let s = reader.summary
            let node = ClaudeAgentNode(
                id: agentId,
                parentId: meta.parentAgentId,
                description: meta.description,
                agentType: meta.agentType,
                depth: meta.spawnDepth ?? 1,
                state: Self.baseState(s, mtime: mt, now: now, t: thresholds),
                startedAt: s.firstTimestamp ?? mtime(metaURL) ?? mt,
                lastActivityAt: max(s.lastTimestamp ?? mt, mt),
                totalTokens: s.contextTokens,
                lastTool: s.lastTool,
                transcriptURL: jsonl,
                children: []
            )
            flat[agentId] = Flat(meta: meta, node: node, summary: s, mtime: mt)
        }
        if flat.isEmpty {
            // Só a conversa principal: aparece enquanto está ativa.
            guard let m = mtime(mainURL), now.timeIntervalSince(m) <= thresholds.mainOnly else { return nil }
            return ClaudeSession(id: id, projectName: projectName(sessionId: id, mainURL: mainURL, project: project),
                                 lastActivityAt: m, agents: [], host: host)
        }

        // Monta a árvore (pais desconhecidos e nós em ciclo viram raízes).
        let parents = Self.resolveParents(flat.mapValues { $0.meta.parentAgentId })
        var childrenOf: [String?: [String]] = [:]
        for id in flat.keys {
            childrenOf[parents[id] ?? nil, default: []].append(id)
        }
        var visiting = Set<String>()
        func build(_ id: String, depth: Int) -> ClaudeAgentNode {
            var n = flat[id]!.node
            visiting.insert(id)
            let kids = (childrenOf[id] ?? []).filter { !visiting.contains($0) }
                .map { build($0, depth: depth + 1) }
                .sorted { $0.startedAt < $1.startedAt }
            visiting.remove(id)
            let s = flat[id]!.summary
            // Orquestrador que encerrou o turno esperando filhos em background continua "rodando".
            let waitingKids = n.state == .done && !s.handedBack && kids.contains { $0.state == .running }
            n = ClaudeAgentNode(id: n.id, parentId: n.parentId, description: n.description, agentType: n.agentType,
                                depth: flat[id]!.meta.spawnDepth ?? depth, state: waitingKids ? .running : n.state,
                                startedAt: n.startedAt, lastActivityAt: n.lastActivityAt, totalTokens: n.totalTokens,
                                lastTool: n.lastTool, transcriptURL: n.transcriptURL, children: kids)
            return n
        }
        let roots = (childrenOf[nil] ?? []).map { build($0, depth: 1) }.sorted { $0.startedAt < $1.startedAt }

        let mainMtime = mtime(mainURL)
        let last = ([mainMtime] + flat.values.map { Optional($0.node.lastActivityAt) }).compactMap { $0 }.max() ?? now
        guard now.timeIntervalSince(last) <= thresholds.window else { return nil }
        return ClaudeSession(id: id, projectName: projectName(sessionId: id, mainURL: mainURL, project: project),
                             lastActivityAt: last, agents: roots, host: host)
    }

    /// Pai efetivo de cada agente: nil quando o pai é desconhecido, é o próprio nó ou o nó está num ciclo
    /// (A→B→A). Nós pendurados num ciclo continuam filhos do nó do ciclo, que vira raiz.
    static func resolveParents(_ declared: [String: String?]) -> [String: String?] {
        var out: [String: String?] = [:]
        for (id, p) in declared {
            guard let p, p != id, declared[p] != nil else { out[id] = .some(nil); continue }
            // Sobe a cadeia; se voltar ao próprio nó, ele está num ciclo.
            var cur: String? = p
            var steps = 0
            var inCycle = false
            while let c = cur, steps <= declared.count {
                if c == id { inCycle = true; break }
                cur = declared[c] ?? nil
                steps += 1
            }
            out[id] = .some(inCycle ? nil : p)
        }
        return out
    }

    // MARK: - Regras de estado

    static func baseState(_ s: ClaudeTranscriptSummary, mtime: Date, now: Date, t: Thresholds) -> ClaudeAgentState {
        let idle = now.timeIntervalSince(mtime)
        if s.handedBack { return .done }
        if s.lastAssistantIsError && s.lastEventType == "assistant" && idle >= t.recentWrite { return .failed }
        if s.lastEventType == "assistant", s.lastAssistantStopReason == "end_turn", s.pendingToolIds.isEmpty {
            return .done
        }
        if idle < t.recentWrite { return .running }
        // Sem fechamento: tool pendente ou aguardando resposta do modelo.
        return idle < t.abandoned ? .running : .failed
    }

    // MARK: - Auxiliares

    private func loadMeta(_ url: URL) -> Meta? {
        let mt = mtime(url) ?? .distantPast
        if let c = metas[url.path], c.mtime == mt { return c.meta }
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let meta = Meta(agentType: o["agentType"] as? String ?? "agent",
                        description: o["description"] as? String ?? "",
                        parentAgentId: (o["parentAgentId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        spawnDepth: (o["spawnDepth"] as? NSNumber)?.intValue)
        metas[url.path] = (mt, meta)
        return meta
    }

    private func projectName(sessionId: String, mainURL: URL, project: URL) -> String {
        if let c = sessionCwd[sessionId] { return URL(fileURLWithPath: c).lastPathComponent }
        if let cwd = Self.firstCwd(in: mainURL) {
            sessionCwd[sessionId] = cwd
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        // Fallback: nome sanitizado da pasta (/ e . viram -); devolve o último trecho.
        return project.lastPathComponent.split(separator: "-").last.map(String.init) ?? project.lastPathComponent
    }

    /// cwd do primeiro registro que o tiver (lê no máximo 256 KB do início).
    static func firstCwd(in url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 256 << 10) else { return nil }
        for line in data.split(separator: 0x0A) {
            if let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let c = o["cwd"] as? String, !c.isEmpty { return c }
        }
        return nil
    }

    private func mtime(_ url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
}
