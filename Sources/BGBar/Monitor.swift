import Foundation
import Observation

/// Estado central: faz polling, guarda itens, fixados/ocultos e detecta quedas.
@MainActor
@Observable
final class Monitor {
    static let shared = Monitor()

    private(set) var agents: [Item] = []
    private(set) var docker: [Item] = []
    private(set) var dev: [Item] = []
    private(set) var dockerAvailable = true
    /// Máquinas remotas (destinos do ssh), na ordem em que foram adicionadas.
    private(set) var hosts: [String] {
        didSet { UserDefaults.standard.set(hosts, forKey: "remoteHosts") }
    }
    private(set) var remote: [String: RemoteHost] = [:]
    /// Filtro global por máquina: "" = todas, `thisMac` ou um host remoto.
    /// Vale para listas, contagens e cabeçalho; o ícone da barra continua olhando tudo.
    var machine: String {
        didSet { UserDefaults.standard.set(machine, forKey: "machineFilter") }
    }
    /// Valor de `machine` para "só este Mac" ("*" não é válido em destino ssh).
    static let thisMac = "*mac"
    private(set) var lastUpdate: Date?
    private(set) var isRefreshing = false
    /// Mensagem transitória para a UI (erro/sucesso de ação).
    var toast: String?
    /// IDs com ação em andamento (para spinner na linha). Dono: `Actions` (a UI só lê).
    var busy: Set<String> = []

    var showHidden: Bool {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") }
    }
    private(set) var pinned: Set<String> {
        didSet { UserDefaults.standard.set(Array(pinned), forKey: "pinned") }
    }
    private(set) var hidden: Set<String> {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hidden") }
    }
    /// Metadados de itens fixados, para mostrar linha "fantasma" quando somem.
    private var pinnedMeta: [String: [String]] {
        didSet { UserDefaults.standard.set(pinnedMeta, forKey: "pinnedMeta") }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var remoteLoops: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var previous: [String: Item] = [:]
    @ObservationIgnored private var suppressedUntil: [String: Date] = [:]
    @ObservationIgnored private var dockerStats: [String: Docker.Stat] = [:]
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var dockerBackoff = 0
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var statsInFlight = false

    private init() {
        let d = UserDefaults.standard
        showHidden = d.bool(forKey: "showHidden")
        let saved = (d.stringArray(forKey: "remoteHosts") ?? []).filter(Remote.isValidHost)
        hosts = saved
        let filter = d.string(forKey: "machineFilter") ?? ""
        machine = filter == Self.thisMac || saved.contains(filter) ? filter : ""
        pinned = Set(d.stringArray(forKey: "pinned") ?? [])
        hidden = Set(d.stringArray(forKey: "hidden") ?? [])
        pinnedMeta = (d.dictionary(forKey: "pinnedMeta") as? [String: [String]]) ?? [:]
    }

    // MARK: Ciclo

    func start(interval: TimeInterval = 2.5) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        hosts.forEach(pollRemote)
        ClaudeAgentsStore.shared.setHosts(hosts)
    }

    /// Pede uma rodada já. Se uma estiver em andamento (com dados possivelmente
    /// anteriores a uma ação), agenda outra logo em seguida em vez de descartar.
    func refreshNow() {
        hosts.forEach(pollRemote)
        if isRefreshing { refreshAgain = true; return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshAgain {
                refreshAgain = false
                Task { await refresh() }
            }
        }
        tick += 1

        let wantDocker = dockerBackoff == 0
        if dockerBackoff > 0 { dockerBackoff -= 1 }
        let snap = await Self.collect(includeDocker: wantDocker)

        agents = snap.agents
        dev = snap.dev
        if wantDocker {
            if let d = snap.docker {
                dockerAvailable = true
                docker = d
            } else {
                dockerAvailable = false
                docker = []
                dockerBackoff = 6 // ~15 s até tentar de novo
            }
        }
        applyDockerStats()
        if dockerAvailable, !statsInFlight, tick % 4 == 1 {
            statsInFlight = true
            Task { [weak self] in
                let stats = await Docker.stats() // nonisolated: roda fora da main
                guard let self else { return }
                self.statsInFlight = false
                self.dockerStats = stats
                self.applyDockerStats()
            }
        }

        detectDrops()
        lastUpdate = Date()
    }

    private struct Snapshot: Sendable {
        var agents: [Item]
        var docker: [Item]?
        var dev: [Item]
    }

    /// Roda fora da main thread (nonisolated + async).
    nonisolated private static func collect(includeDocker: Bool) async -> Snapshot {
        async let procsT = ProcTable.load()
        async let portsT = Ports.load()
        async let dockerT: [Item]? = includeDocker ? Docker.collect() : nil
        let procs = await procsT
        let ports = await portsT
        let agents = await LaunchAgents.collect(procs: procs, ports: ports)
        let owned = LaunchAgents.ownedPIDs(agents, procs: procs)
        let dev = await DevProcs.collect(procs: procs, ports: ports, excluded: owned)
        return Snapshot(agents: agents, docker: await dockerT, dev: dev)
    }

    // MARK: Máquinas remotas (ssh)

    struct RemoteHost: Sendable, Equatable {
        var items: [Item] = []
        /// Última coleta deu certo.
        var online = false
        /// Já houve ao menos uma tentativa (antes disso: "conectando").
        var checked = false
        var error: String?
        /// Nome de rede real (o destino pode ser um alias do ~/.ssh/config).
        var hostname: String?
        var failures = 0
    }

    static let remoteInterval: TimeInterval = 5

    /// Devolve a mensagem de erro, ou nil se adicionou.
    func addHost(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(in: .whitespaces)
        guard Remote.isValidHost(host) else { return "Destino ssh inválido: use um alias, host ou usuário@host" }
        guard !hosts.contains(host) else { return "\(host) já está na lista" }
        hosts.append(host)
        pollRemote(host)
        ClaudeAgentsStore.shared.setHosts(hosts)
        return nil
    }

    func removeHost(_ host: String) {
        remoteLoops.removeValue(forKey: host)?.cancel()
        hosts.removeAll { $0 == host }
        if machine == host || hosts.isEmpty { machine = "" }
        ClaudeAgentsStore.shared.setHosts(hosts)
        remote[host] = nil
    }

    var offlineHosts: [String] { hosts.filter { remote[$0].map { $0.checked && !$0.online } ?? false } }

    /// (Re)inicia o ciclo do host, coletando já. Cada host tem o seu ciclo, fora do
    /// `refresh` local: uma máquina lenta ou fora do ar não atrasa o resto.
    private func pollRemote(_ host: String) {
        remoteLoops[host]?.cancel()
        remoteLoops[host] = Task { [weak self] in
            if self?.remote[host]?.hostname == nil, let name = await Remote.hostname(host), !Task.isCancelled {
                self?.remote[host, default: RemoteHost()].hostname = name
            }
            while !Task.isCancelled {
                let result = await Remote.collect(host) // nonisolated: roda fora da main
                guard !Task.isCancelled, let self else { return }
                self.applyRemote(host, result)
                try? await Task.sleep(for: .seconds(Self.remoteInterval))
            }
        }
    }

    private func applyRemote(_ host: String, _ result: Remote.Collected) {
        var state = remote[host] ?? RemoteHost()
        state.checked = true
        if let items = result.items {
            state.items = items
            state.online = true
            state.error = nil
            state.failures = 0
        } else {
            // Uma falha isolada mantém a última lista; na segunda o host conta como fora do ar.
            state.failures += 1
            state.error = result.error
            if state.failures >= 2 || !state.online {
                state.online = false
                state.items = []
            }
        }
        if remote[host] != state { remote[host] = state }
    }

    private func applyDockerStats() {
        guard !dockerStats.isEmpty else { return }
        docker = docker.map { item in
            var i = item
            if i.status.isUp || i.status == .unhealthy, let s = dockerStats[i.name] {
                i.cpu = s.cpu
                i.memBytes = s.mem
            }
            return i
        }
    }

    // MARK: Quedas e notificações

    /// Evita notificar quedas causadas pelo próprio app (stop/restart/kill).
    func suppressNotifications(for id: String, seconds: TimeInterval = 20) {
        let until = Date().addingTimeInterval(seconds)
        suppressedUntil[id] = max(until, suppressedUntil[id] ?? until)
    }

    private func detectDrops() {
        let current = Kind.allCases.flatMap(all)
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        defer { previous = byID }
        guard !previous.isEmpty else { return }
        let now = Date()

        for (id, old) in previous where old.status.isUp {
            if hidden.contains(old.key) { continue }
            // Máquina fora do ar (ou removida) não é queda dos itens dela.
            if let host = old.host, remote[host]?.online != true { continue }
            if let until = suppressedUntil[id], until > now { continue }
            let new = byID[id]
            switch old.kind {
            case .agent:
                guard let new, !new.status.isUp else { continue }
                Notifier.shared.notifyDown(new, previous: old)
            case .docker:
                // Container removido (ex.: recriado pelo compose) não conta como queda.
                guard let new, !new.status.isUp else { continue }
                Notifier.shared.notifyDown(new, previous: old)
            case .dev:
                // Processos de dev só notificam se fixados.
                guard pinned.contains(old.key), !(new?.status.isUp ?? false) else { continue }
                var gone = old
                gone.status = .stopped
                gone.pid = nil
                Notifier.shared.notifyDown(gone, previous: old)
            }
        }
        suppressedUntil = suppressedUntil.filter { $0.value > now }
    }

    // MARK: Fixar / ocultar

    func isPinned(_ item: Item) -> Bool { pinned.contains(item.key) }
    func isHidden(_ item: Item) -> Bool { hidden.contains(item.key) }

    func togglePin(_ item: Item) {
        if pinned.contains(item.key) {
            pinned.remove(item.key)
            pinnedMeta[item.key] = nil
        } else {
            pinned.insert(item.key)
            hidden.remove(item.key)
            pinnedMeta[item.key] = [item.kind.rawValue, item.name, item.detail, item.workingDir ?? "", item.host ?? ""]
        }
    }

    func toggleHidden(_ item: Item) {
        if hidden.contains(item.key) {
            hidden.remove(item.key)
        } else {
            hidden.insert(item.key)
            pinned.remove(item.key)
            pinnedMeta[item.key] = nil
        }
    }

    // MARK: Consultas para a UI

    func all(_ kind: Kind) -> [Item] {
        let local = switch kind {
        case .agent: agents
        case .docker: docker
        case .dev: dev
        }
        guard !hosts.isEmpty else { return local }
        return local + hosts.flatMap { remote[$0]?.items ?? [] }.filter { $0.kind == kind }
    }

    /// Itens visíveis da seção, ordenados: fixados, problemas, rodando, resto.
    /// Inclui linhas fantasma de fixados que não estão presentes.
    func items(_ kind: Kind) -> [Item] { items(kind, machine: machine) }

    /// O filtro de máquina deixa passar algo desta máquina (nil = este Mac)?
    func showsMachine(_ host: String?) -> Bool {
        hosts.isEmpty || machine.isEmpty || host == (machine == Self.thisMac ? nil : machine)
    }

    /// Itens do tipo na máquina pedida ("" = todas).
    private func scoped(_ kind: Kind, machine: String) -> [Item] {
        let list = all(kind)
        guard !hosts.isEmpty, !machine.isEmpty else { return list }
        let host = machine == Self.thisMac ? nil : machine
        return list.filter { $0.host == host }
    }

    private func items(_ kind: Kind, machine: String) -> [Item] {
        var list = scoped(kind, machine: machine).filter { showHidden || !hidden.contains($0.key) }
        let presentKeys = Set(all(kind).map(\.key))
        for key in pinned where !presentKeys.contains(key) {
            guard let meta = pinnedMeta[key], meta.count >= 4, meta[0] == kind.rawValue else { continue }
            var ghost = Item(id: key, key: key, kind: kind, name: meta[1], detail: meta[2], status: .stopped)
            ghost.workingDir = meta[3].isEmpty ? nil : meta[3]
            if meta.count >= 5, !meta[4].isEmpty {
                // Sem a máquina no ar não dá para dizer que o item sumiu.
                guard remote[meta[4]]?.online == true else { continue }
                ghost.host = meta[4]
            }
            if !hosts.isEmpty, !machine.isEmpty, ghost.host != (machine == Self.thisMac ? nil : machine) { continue }
            ghost.statusNote = "não encontrado"
            ghost.isGhost = true
            list.append(ghost)
        }
        func rank(_ i: Item) -> Int {
            var r = 0
            if !pinned.contains(i.key) { r += 100 }
            switch i.status {
            case .failed, .unhealthy: r += 0
            case .restarting, .starting: r += 10
            case .running: r += 20
            case .stopped, .notLoaded: r += 30
            }
            return r
        }
        return list.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func hiddenCount(_ kind: Kind? = nil) -> Int {
        let kinds = kind.map { [$0] } ?? Kind.allCases
        return kinds.reduce(0) { $0 + scoped($1, machine: machine).filter { hidden.contains($0.key) }.count }
    }

    /// Busca também entre ocultos (o detalhe não pode "sumir" ao ocultar o item) e fantasmas.
    func item(id: String) -> Item? {
        for k in Kind.allCases { if let i = all(k).first(where: { $0.id == id }) { return i } }
        for k in Kind.allCases { if let i = items(k).first(where: { $0.id == id && $0.isGhost }) { return i } }
        return nil
    }

    /// Itens que contam como problema para o indicador da barra.
    var problems: [Item] { problems(machine: machine) }

    private func problems(machine: String) -> [Item] {
        Kind.allCases.flatMap { items($0, machine: machine) }.filter { i in
            if hidden.contains(i.key) { return false }
            let isPinned = pinned.contains(i.key)
            switch i.status {
            case .unhealthy, .restarting, .starting: return true
            case .failed:
                // Containers parados com erro antigo só contam se fixados.
                return i.kind != .docker || isPinned
            case .stopped, .notLoaded: return isPinned
            case .running: return false
            }
        }
    }

    var health: Health { Self.health(of: problems) }

    /// Saúde de todas as máquinas, ignorando o filtro (ícone da barra de menus).
    var overallHealth: Health { Self.health(of: problems(machine: "")) }

    /// Saúde só de uma aba: o ponto da aba acende pelos mesmos critérios do cabeçalho.
    func health(_ kind: Kind) -> Health { Self.health(of: problems.filter { $0.kind == kind }) }

    private static func health(of p: [Item]) -> Health {
        if p.contains(where: { $0.status == .failed || $0.status == .unhealthy || ($0.isGhost) || ($0.status == .stopped || $0.status == .notLoaded) }) {
            return .critical
        }
        if !p.isEmpty { return .warning }
        return .ok
    }

    var runningCount: Int {
        Kind.allCases.flatMap { items($0) }.filter { $0.status.isUp || $0.status == .unhealthy }.count
    }
}
