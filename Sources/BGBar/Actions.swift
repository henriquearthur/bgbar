import AppKit
import Darwin
import UniformTypeIdentifiers

/// Ações sobre itens (LaunchAgents, containers, processos). Todo trabalho
/// bloqueante roda fora da main thread (via `Shell.run` ou `Task.detached`).
@MainActor
enum Actions {
    enum LogApp { case console, editor, finder }

    static func canStart(_ item: Item) -> Bool { item.kind != .dev && !item.status.isUp && !item.isGhost }
    static func canStop(_ item: Item) -> Bool { item.kind != .dev && (item.status.isUp || item.status == .unhealthy || item.status == .restarting) }
    static func canRestart(_ item: Item) -> Bool { item.kind != .dev && !item.isGhost && item.status != .notLoaded }
    static func canKill(_ item: Item) -> Bool { (item.pid ?? 0) > 1 && !item.isGhost }
    /// Serviço systemd remoto sempre tem log (journal).
    static func hasLog(_ item: Item) -> Bool {
        item.kind == .docker || !item.logPaths.isEmpty || (item.host != nil && item.kind == .agent && !item.isGhost)
    }

    // MARK: Execução (ponto único: busy + supressão + toast + refresh)

    enum Op: Equatable {
        case start, stop, restart, kill(force: Bool)
        /// Ops que derrubam o item: a queda não deve virar notificação.
        var suppressesDrop: Bool { self != .start }
    }

    /// Entrada recomendada para a UI (dispara e esquece). Ignora clique repetido enquanto
    /// o item está ocupado. Confirmações (kill, parar, reiniciar) ficam na UI, antes daqui.
    static func run(_ op: Op, on item: Item) {
        guard !Monitor.shared.busy.contains(item.id) else { return }
        Monitor.shared.busy.insert(item.id) // marca já, antes do Task começar
        Task { @MainActor in await perform(op, item) }
    }

    /// Único lugar que mexe em busy, supressão de notificação, toast e refresh.
    private static func perform(_ op: Op, _ item: Item) async {
        let monitor = Monitor.shared
        monitor.busy.insert(item.id)
        if op.suppressesDrop { monitor.suppressNotifications(for: item.id, seconds: 30) }
        let message = await execute(op, item)
        // `docker stop` pode levar até ~10 s: estende a janela a partir do fim da ação.
        if op.suppressesDrop { monitor.suppressNotifications(for: item.id, seconds: 15) }
        monitor.busy.remove(item.id)
        if let message { toast(message) }
        monitor.refreshNow()
    }

    private static func execute(_ op: Op, _ item: Item) async -> String? {
        if let host = item.host { return await doRemote(op, item, host: host) }
        switch op {
        case .start: return await doStart(item)
        case .stop: return await doStop(item)
        case .restart: return await doRestart(item)
        case .kill(let force): return await doKill(item, force: force)
        }
    }

    private static func doStart(_ item: Item) async -> String? {
        switch item.kind {
        case .agent:
            if item.status == .notLoaded {
                guard let plist = item.plistPath else { return "Sem plist para \(item.name)" }
                return report(await bootstrap(plist), item, verb: "iniciar", done: "\(item.name) iniciado")
            }
            guard let target = agentTarget(item) else { return "Sem label para \(item.name)" }
            return report(await launchctl(["kickstart", target]), item, verb: "iniciar", done: "\(item.name) iniciado")
        case .docker:
            return await docker(item, "start", verb: "iniciar", done: "\(item.name) iniciado")
        case .dev:
            return nil
        }
    }

    private static func doStop(_ item: Item) async -> String? {
        switch item.kind {
        case .agent:
            guard let target = agentTarget(item) else { return "Sem label para \(item.name)" }
            return report(await launchctl(["bootout", target]), item, verb: "parar", done: "\(item.name) parado")
        case .docker:
            return await docker(item, "stop", verb: "parar", done: "\(item.name) parado")
        case .dev:
            return nil
        }
    }

    private static func doRestart(_ item: Item) async -> String? {
        switch item.kind {
        case .agent:
            if item.status == .notLoaded, let plist = item.plistPath {
                return report(await bootstrap(plist), item, verb: "reiniciar", done: "\(item.name) iniciado")
            }
            guard let target = agentTarget(item) else { return "Sem label para \(item.name)" }
            return report(await launchctl(["kickstart", "-k", target]), item, verb: "reiniciar", done: "\(item.name) reiniciado")
        case .docker:
            return await docker(item, "restart", verb: "reiniciar", done: "\(item.name) reiniciado")
        case .dev:
            return nil
        }
    }

    /// Mesma ação, executada por ssh na máquina do item (systemctl --user, docker, kill).
    private static func doRemote(_ op: Op, _ item: Item, host: String) async -> String? {
        guard let script = Remote.actionScript(op, item) else { return nil }
        let r = await Remote.run(host, script, timeout: 40)
        switch op {
        case .start: return report(r, item, verb: "iniciar", done: "\(item.name) iniciado")
        case .stop: return report(r, item, verb: "parar", done: "\(item.name) parado")
        case .restart: return report(r, item, verb: "reiniciar", done: "\(item.name) reiniciado")
        case .kill(let force):
            let pid = item.pid.map(String.init) ?? "?"
            if r.status == 3 { return "\(item.name) (PID \(pid)) já não existe" }
            if r.status == 4 { return "PID \(pid) agora é outro processo; não encerrei" }
            return report(r, item, verb: "encerrar", done: "\(force ? "SIGKILL" : "SIGTERM") enviado para \(item.name) (PID \(pid))")
        }
    }

    /// SIGTERM (ou SIGKILL se force). A UI já pediu confirmação antes de chamar.
    /// Recusa PID ≤ 1, o próprio BGBar, processo de outro usuário e PID reaproveitado
    /// (início do processo atual diferente do que a lista mostrava).
    private static func doKill(_ item: Item, force: Bool) async -> String {
        guard let pid = item.pid, pid > 1, pid != getpid() else {
            return "\(item.name) não tem PID válido"
        }
        guard let info = processInfo(pid) else {
            return "\(item.name) (PID \(pid)) já não existe"
        }
        guard info.uid == getuid() else {
            return "PID \(pid) não é seu; não encerrei"
        }
        if let expected = item.startedAt, abs(info.start.timeIntervalSince(expected)) > 5 {
            return "PID \(pid) agora é outro processo; não encerrei"
        }
        let signal = force ? SIGKILL : SIGTERM
        guard Darwin.kill(pid, signal) == 0 else {
            return "Falha ao encerrar \(item.name): \(String(cString: strerror(errno)))"
        }
        try? await Task.sleep(for: .milliseconds(400))
        return "\(force ? "SIGKILL" : "SIGTERM") enviado para \(item.name) (PID \(pid))"
    }

    /// Dono e hora de início de um PID via sysctl (sem processo externo).
    nonisolated static func processInfo(_ pid: Int32) -> (uid: uid_t, start: Date)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        let start = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
        return (info.kp_eproc.e_ucred.cr_uid, start)
    }

    // MARK: Utilidades simples

    /// Endereço para abrir portas do item: localhost ou o nome de rede da máquina remota.
    static func portHost(_ host: String?) -> String {
        guard let host else { return "localhost" }
        return Monitor.shared.remote[host]?.hostname ?? host.split(separator: "@").last.map(String.init) ?? host
    }

    static func openPort(_ port: Int, host: String? = nil) {
        guard let url = URL(string: "http://\(portHost(host)):\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyPID(_ item: Item) {
        guard let pid = item.pid else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(String(pid), forType: .string)
        toast("PID \(pid) copiado")
    }

    // MARK: Logs

    static func openLog(_ item: Item, in app: LogApp) async {
        var urls: [URL]
        if item.kind == .docker || item.host != nil {
            guard let url = await dumpLog(item) else { return }
            urls = [url]
        } else {
            let paths = item.logPaths
            let existing = await Task.detached { paths.filter { FileManager.default.fileExists(atPath: $0) } }.value
            guard !existing.isEmpty else {
                toast(paths.isEmpty ? "\(item.name) não tem log" : "Log de \(item.name) não existe")
                return
            }
            urls = existing.map { URL(fileURLWithPath: $0) }
        }

        let ws = NSWorkspace.shared
        switch app {
        case .finder:
            ws.activateFileViewerSelecting(urls)
        case .console:
            let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
            await open(Array(urls.prefix(1)), with: console, name: item.name)
        case .editor:
            let editor = ws.urlForApplication(toOpen: UTType.plainText)
                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            await open(urls, with: editor, name: item.name)
        }
    }

    /// Últimas linhas do log (arquivo ou `docker logs`). Fora da main thread.
    static func logTail(_ item: Item, lines: Int = 200) async -> String {
        let n = max(1, lines)
        if item.kind == .docker || item.host != nil {
            guard let r = await commandLog(item, lines: n, timeout: 15) else { return "Este item não tem log." }
            if !r.ok && r.out.isEmpty {
                let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Falha ao ler logs de \(item.name): \(err.isEmpty ? "exit \(r.status)" : err)"
            }
            let text = combine(out: r.out, err: r.err)
            return text.isEmpty ? "(log vazio)" : lastLines(text, n)
        }

        var seen = Set<String>()
        let paths = item.logPaths.filter { seen.insert($0).inserted }
        guard !paths.isEmpty else {
            return "Este item não tem arquivo de log configurado (StandardOutPath/StandardErrorPath)."
        }
        return await Task.detached(priority: .utility) {
            let labeled = paths.count > 1
            var parts: [String] = []
            for path in paths {
                let short = Fmt.abbreviateHome(path)
                let header = labeled ? "==> \(short) <==\n" : ""
                guard FileManager.default.fileExists(atPath: path) else {
                    parts.append(header + "(arquivo não existe: \(short))")
                    continue
                }
                guard let tail = readTail(path: path, maxBytes: 64 * 1024) else {
                    parts.append(header + "(não foi possível ler \(short))")
                    continue
                }
                let body = lastLines(tail, n)
                parts.append(header + (body.isEmpty ? "(log vazio)" : body))
            }
            return parts.joined(separator: "\n\n")
        }.value
    }

    // MARK: - Privado

    private static var domain: String { "gui/\(getuid())" }

    private static func agentTarget(_ item: Item) -> String? {
        guard let label = item.label, !label.isEmpty else { return nil }
        return "\(domain)/\(label)"
    }

    private static func launchctl(_ args: [String]) async -> Shell.Result {
        await Shell.run("/bin/launchctl", args, timeout: 15)
    }

    private static func bootstrap(_ plist: String) async -> Shell.Result {
        await launchctl(["bootstrap", domain, plist])
    }

    private static func docker(_ item: Item, _ cmd: String, verb: String, done: String) async -> String {
        guard let id = item.containerID else { return "Container sem ID: \(item.name)" }
        return report(await Shell.run("docker", [cmd, id], timeout: 35), item, verb: verb, done: done)
    }

    private static func report(_ r: Shell.Result, _ item: Item, verb: String, done: String) -> String {
        r.ok ? done : "Falha ao \(verb) \(item.name): \(errorText(r))"
    }

    private static func errorText(_ r: Shell.Result) -> String {
        let raw = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.isEmpty ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        guard !text.isEmpty else { return "exit \(r.status)" }
        let line = text.split(separator: "\n").last.map(String.init) ?? text
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    private static func toast(_ msg: String) {
        Monitor.shared.toast = msg
    }

    private static func open(_ urls: [URL], with app: URL, name: String) async {
        guard !urls.isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config)
        } catch {
            toast("Falha ao abrir log de \(name): \(error.localizedDescription)")
        }
    }

    /// Log que vem de um comando e não de um arquivo local: `docker logs` e, em máquina
    /// remota, o equivalente por ssh (docker, journal do systemd ou `tail`). nil = sem log.
    private static func commandLog(_ item: Item, lines: Int, timeout: TimeInterval) async -> Shell.Result? {
        if let host = item.host {
            guard let script = Remote.logScript(item, lines: lines) else { return nil }
            return await Remote.run(host, script, timeout: timeout)
        }
        guard let id = item.containerID else { return nil }
        return await Shell.run("docker", ["logs", "--tail", String(lines), id], timeout: timeout)
    }

    /// Grava as últimas 2000 linhas de `commandLog` num arquivo temporário e devolve a URL.
    private static func dumpLog(_ item: Item) async -> URL? {
        guard let r = await commandLog(item, lines: 2000, timeout: 20) else {
            toast("\(item.name) não tem log")
            return nil
        }
        if !r.ok && r.out.isEmpty {
            toast("Falha ao ler logs de \(item.name): \(errorText(r))")
            return nil
        }
        let text = combine(out: r.out, err: r.err)
        let safe = String(item.name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bgbar-\(safe).log")
        let ok = await Task.detached { () -> Bool in
            (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
        }.value
        guard ok else {
            toast("Falha ao gravar log temporário de \(item.name)")
            return nil
        }
        return url
    }

    /// Junta stdout e stderr do `docker logs` (a intercalação exata se perde).
    nonisolated private static func combine(out: String, err: String) -> String {
        let o = out.trimmingCharacters(in: .newlines)
        let e = err.trimmingCharacters(in: .newlines)
        if o.isEmpty { return e }
        if e.isEmpty { return o }
        return o + "\n" + e
    }

    nonisolated private static func lastLines(_ text: String, _ n: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        let all = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(n).joined(separator: "\n")
    }

    /// Lê só os últimos `maxBytes` do arquivo, descartando a primeira linha parcial.
    nonisolated private static func readTail(path: String, maxBytes: UInt64) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        do {
            let size = try fh.seekToEnd()
            let start = size > maxBytes ? size - maxBytes : 0
            try fh.seek(toOffset: start)
            let data = try fh.readToEnd() ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            if start > 0, let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            return text
        } catch {
            return nil
        }
    }
}
