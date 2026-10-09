import Foundation

// Máquinas Linux monitoradas por ssh. Cada rodada é UMA chamada `ssh <host> sh` com o
// script de coleta no stdin (independe do shell de login remoto); a saída vem em seções
// `@@bgbar:<nome>` e é interpretada por funções puras, reaproveitando os parsers locais
// (`ProcTable`, `Docker`, `DevProcs`). O equivalente aos LaunchAgents são os serviços
// systemd do usuário em ~/.config/systemd/user.

enum Remote {
    /// Prefixo de `Item.id`/`Item.key` de itens remotos (não colide com os locais).
    static func prefix(_ host: String) -> String { "ssh:\(host)|" }

    /// Destino aceito pelo ssh: alias do ~/.ssh/config, `host` ou `usuário@host`.
    /// Recusa espaços e "-" inicial (viraria opção do ssh).
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 255, !host.hasPrefix("-") else { return false }
        return host.unicodeScalars.allSatisfy { c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || "._-@:[]%".unicodeScalars.contains(c))
        }
    }

    // MARK: ssh

    /// Sem interação (chave/agente; nunca pede senha) e com conexão compartilhada entre
    /// rodadas (ControlMaster), para não renegociar a cada coleta.
    static let sshOptions = [
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
        "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/bgbar-%C", "-o", "ControlPersist=120",
        "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
    ]

    static let preamble = """
        export LC_ALL=C
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

        """

    static func run(_ host: String, _ script: String, timeout: TimeInterval) async -> Shell.Result {
        guard isValidHost(host) else { return Shell.Result(status: 64, out: "", err: "host inválido: \(host)") }
        return await Shell.run("/usr/bin/ssh", sshOptions + ["--", host, "sh"], timeout: timeout,
                               input: preamble + script)
    }

    /// Nome de rede real do destino (resolve alias do ~/.ssh/config), para abrir portas no navegador.
    static func hostname(_ host: String) async -> String? {
        guard isValidHost(host) else { return nil }
        let r = await Shell.run("/usr/bin/ssh", ["-G", "--", host], timeout: 4)
        return parseHostname(r.out)
    }

    /// Saída de `ssh -G`: linhas "chave valor".
    static func parseHostname(_ out: String) -> String? {
        for line in out.split(separator: "\n") where line.hasPrefix("hostname ") {
            return String(line.dropFirst("hostname ".count))
        }
        return nil
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Coleta

    static let unitProps = "Id,LoadState,ActiveState,SubState,MainPID,ExecMainStatus,FragmentPath,ExecStart,WorkingDirectory"

    static let collectScript = """
        echo '@@bgbar:ps'
        ps -u "$(id -u)" -ww -o pid=,ppid=,etime=,pcpu=,rss=,args=
        echo '@@bgbar:allps'
        ps -e -o pid=,ppid=,etime=,pcpu=,rss=,comm=
        echo '@@bgbar:ports'
        ss -Hltnp 2>/dev/null
        echo '@@bgbar:fd'
        find /proc/[0-9]*/cwd /proc/[0-9]*/fd/1 /proc/[0-9]*/fd/2 -maxdepth 0 -user "$(id -u)" -printf '%p\\t%l\\n' 2>/dev/null
        echo '@@bgbar:units'
        if cd "$HOME/.config/systemd/user" 2>/dev/null; then
          set --
          for f in *.service; do
            case "$f" in '*.service'|*@.service) ;; *) set -- "$@" "$f" ;; esac
          done
          [ $# -gt 0 ] && systemctl --user show "$@" --no-pager -p \(unitProps) 2>/dev/null
        fi
        echo '@@bgbar:docker'
        if docker ps -a --no-trunc --format '{{json .}}' 2>/dev/null; then
          echo '@@bgbar:inspect'
          ids=$(docker ps -q --no-trunc)
          [ -n "$ids" ] && docker inspect --format '{{.Id}} {{.State.StartedAt}}' $ids
          echo '@@bgbar:stats'
          docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
        fi
        echo '@@bgbar:end'

        """

    struct Collected: Sendable {
        /// nil = a coleta falhou (ver `error`).
        var items: [Item]?
        var error: String?
    }

    static func collect(_ host: String) async -> Collected {
        let r = await run(host, collectScript, timeout: 25)
        if let items = parse(r.out, host: host) { return Collected(items: items) }
        return Collected(error: errorText(r))
    }

    static func errorText(_ r: Shell.Result) -> String {
        let text = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = text.split(separator: "\n").last else {
            return r.status == 0 ? "resposta incompleta" : "sem resposta (exit \(r.status))"
        }
        return line.count > 160 ? String(line.prefix(160)) + "…" : String(line)
    }

    /// Seções `@@bgbar:<nome>` -> texto. Linhas em branco são mantidas (separam units).
    static func sections(_ out: String) -> [String: String] {
        var map: [String: [Substring]] = [:]
        var current: String?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@bgbar:") {
                current = String(line.dropFirst("@@bgbar:".count))
                map[current!] = []
            } else if let current {
                map[current, default: []].append(line)
            }
        }
        return map.mapValues { $0.joined(separator: "\n") }
    }

    /// nil se a saída veio truncada (sem a seção final), ex.: timeout ou conexão caiu.
    static func parse(_ out: String, host: String, now: Date = Date()) -> [Item]? {
        let s = sections(out)
        guard s["end"] != nil else { return nil }
        let procs = ProcTable.parse(s["ps"] ?? "")
        let ports = parsePorts(s["ports"] ?? "")
        let fd = parseProcLinks(s["fd"] ?? "")

        let units = parseUnits(s["units"] ?? "").compactMap { unitItem($0, procs: procs, ports: ports, now: now) }

        var docker: [Item] = []
        if let rows = s["docker"] {
            let started = Docker.parseInspect(s["inspect"] ?? "")
            let stats = Docker.parseStats(s["stats"] ?? "")
            docker = Docker.parseRows(rows).map { row in
                var item = Docker.item(row, startedAt: started[row.ID])
                if item.status.isUp || item.status == .unhealthy, let st = stats[item.name] {
                    item.cpu = st.cpu
                    item.memBytes = st.mem
                }
                return item
            }
        }

        // Fora de "dev": o que já é de um serviço e tudo que desce de um shim de container
        // (processo de container pode rodar com o uid do usuário; o shim é do root, por isso
        // a árvore vem do `ps -e`, onde `comm` tem no máximo 15 caracteres).
        var excluded = LaunchAgents.ownedPIDs(units, procs: procs)
        let everyone = ProcTable.parse(s["allps"] ?? "")
        for p in everyone.byPID.values where p.command.hasPrefix("containerd-shim") || p.command == "conmon" {
            excluded.formUnion(everyone.tree(p.pid))
        }
        let roots = DevProcs.roots(procs: procs, excluded: excluded)
        let dev = DevProcs.items(roots: roots, procs: procs, ports: ports, fd: fd, now: now, repoRoot: { _ in nil })

        let pre = prefix(host)
        return (units + docker + dev).map { item in
            var i = item
            i.id = pre + i.id
            i.key = pre + i.key
            i.host = host
            return i
        }
    }

    /// Saída de `ss -Hltnp`:
    /// `LISTEN 0 511 127.0.0.1:3000 0.0.0.0:* users:(("node",pid=12,fd=22),("node",pid=13,fd=22))`.
    /// Sem root, só os sockets do próprio usuário trazem `users:`.
    static func parsePorts(_ out: String) -> [Int32: Set<Int>] {
        var map: [Int32: Set<Int>] = [:]
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 6, let colon = cols[3].lastIndex(of: ":"),
                  let port = Int(cols[3][cols[3].index(after: colon)...]) else { continue }
            for piece in line.components(separatedBy: "pid=").dropFirst() {
                if let pid = Int32(piece.prefix { $0.isNumber }) { map[pid, default: []].insert(port) }
            }
        }
        return map
    }

    /// Linhas "/proc/<pid>/cwd\t<destino>" e "/proc/<pid>/fd/<1|2>\t<destino>" (`find -printf '%p\t%l'`).
    /// stdout/stderr só contam como log quando apontam para arquivo comum.
    static func parseProcLinks(_ out: String) -> DevProcs.FDInfo {
        var info = DevProcs.FDInfo()
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 1)
            guard cols.count == 2 else { continue }
            let comps = cols[0].split(separator: "/")
            let target = String(cols[1])
            guard comps.count >= 3, let pid = Int32(comps[1]), target.hasPrefix("/") else { continue }
            if comps.count == 3 {
                info.cwd[pid] = target
            } else if !target.hasPrefix("/dev/"), !target.hasPrefix("/proc/"), !target.hasSuffix(" (deleted)"),
                      !(info.logs[pid]?.contains(target) ?? false) {
                info.logs[pid, default: []].append(target)
            }
        }
        return info
    }

    /// Saída de `systemctl show u1 u2 …`: blocos "Chave=valor" separados por linha em branco.
    static func parseUnits(_ out: String) -> [[String: String]] {
        var units: [[String: String]] = []
        var cur: [String: String] = [:]
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                if !cur.isEmpty { units.append(cur); cur = [:] }
            } else if let eq = line.firstIndex(of: "=") {
                cur[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        if !cur.isEmpty { units.append(cur) }
        return units
    }

    /// "{ path=/usr/bin/node ; argv[]=/usr/bin/node server.js ; ignore_errors=no ; … }" -> argv.
    static func execArgs(_ raw: String?) -> [String] {
        guard let raw, let start = raw.range(of: "argv[]=") else { return [] }
        let rest = raw[start.upperBound...]
        let argv = rest.range(of: " ; ").map { rest[..<$0.lowerBound] } ?? rest
        return argv.split(separator: " ").map(String.init)
    }

    static func unitItem(_ u: [String: String], procs: ProcTable, ports: [Int32: Set<Int>], now: Date = Date()) -> Item? {
        guard let id = u["Id"], !id.isEmpty, u["LoadState"] != "not-found" else { return nil }
        let argv = execArgs(u["ExecStart"])
        // "!/caminho" e "-/caminho" são modificadores do systemd.
        let wd = u["WorkingDirectory"].map { String($0.drop { $0 == "!" || $0 == "-" }) }.flatMap { $0.hasPrefix("/") ? $0 : nil }
        var item = Item(
            id: "agent:\(id)", key: "agent:\(id)", kind: .agent,
            name: id.hasSuffix(".service") ? String(id.dropLast(".service".count)) : id,
            detail: Summarize.command(argv, cwd: wd), status: .stopped
        )
        item.label = id
        item.plistPath = u["FragmentPath"].flatMap { $0.isEmpty ? nil : $0 }
        item.workingDir = wd
        item.group = wd.map { Summarize.projectName(cwd: $0, args: argv, repoRoot: { _ in nil }) }
        item.command = argv.joined(separator: " ")
        let exit = u["ExecMainStatus"].flatMap { Int($0) }
        let sub = u["SubState"] ?? ""

        switch u["ActiveState"] {
        case "active", "reloading", "deactivating": item.status = .running
        case "activating": item.status = sub == "auto-restart" ? .restarting : .starting
        case "failed":
            item.status = .failed
            item.exitCode = exit
            if let exit, exit != 0 { item.statusNote = "exit \(exit)" }
        default:
            item.status = .stopped
        }
        if item.status != .failed, item.status != .stopped {
            if let pid = u["MainPID"].flatMap({ Int32($0) }), pid > 0 {
                item.pid = pid
                let tree = procs.tree(pid)
                if let p = procs.byPID[pid] { item.startedAt = now.addingTimeInterval(-p.elapsed) }
                let usage = procs.usage(tree)
                item.cpu = usage.cpu
                item.memBytes = usage.memBytes
                item.ports = Ports.collect(tree, ports)
            } else if !sub.isEmpty, sub != "running" {
                item.statusNote = sub // ex.: "exited" (oneshot com RemainAfterExit)
            }
        }
        return item
    }

    // MARK: Ações e logs

    /// Script da ação no host; nil se a ação não se aplica ao item.
    static func actionScript(_ op: Actions.Op, _ item: Item, now: Date = Date()) -> String? {
        if case .kill(let force) = op {
            guard let pid = item.pid, pid > 1 else { return nil }
            // Mesma proteção do kill local contra PID reaproveitado: o tempo de vida atual
            // tem que bater com o que a lista mostrava. Exit 3 = sumiu, 4 = é outro processo.
            let expected = item.startedAt.map { Int(now.timeIntervalSince($0)) }
            let check = expected.map {
                "d=$((e - \($0))); [ \"$d\" -lt 0 ] && d=$((-d)); [ \"$d\" -le 20 ] || exit 4\n"
            } ?? ""
            return """
                e=$(ps -o etimes= -p \(pid) | tr -d ' ')
                [ -n "$e" ] || exit 3
                \(check)kill -\(force ? "KILL" : "TERM") \(pid)

                """
        }
        let verb: String
        switch op {
        case .start: verb = "start"
        case .stop: verb = "stop"
        default: verb = "restart"
        }
        switch item.kind {
        case .agent:
            guard let unit = item.label else { return nil }
            return "systemctl --user \(verb) \(quote(unit))\n"
        case .docker:
            guard let id = item.containerID else { return nil }
            return "docker \(verb) \(quote(id))\n"
        case .dev:
            return nil
        }
    }

    /// Script que imprime as últimas `lines` linhas do log; nil se o item não tem log.
    static func logScript(_ item: Item, lines: Int) -> String? {
        switch item.kind {
        case .docker:
            guard let id = item.containerID else { return nil }
            return "docker logs --tail \(lines) \(quote(id)) 2>&1\n"
        case .agent:
            guard let unit = item.label else { return nil }
            return "journalctl --user -u \(quote(unit)) -n \(lines) --no-pager -o short 2>&1\n"
        case .dev:
            guard !item.logPaths.isEmpty else { return nil }
            return "tail -n \(lines) \(item.logPaths.map(quote).joined(separator: " ")) 2>&1\n"
        }
    }
}
