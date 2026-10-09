import SwiftUI

/// Conteúdo da aba "Agentes Claude": sessões do Claude Code com a árvore completa de
/// subagentes, sempre expandida. Sem card, sem cabeçalho de seção e sem animação.
/// O log de um agente abre num painel de altura fixa embaixo da lista (não empurra linhas).
struct ClaudeAgentsTab: View {
    @ObservedObject private var store = ClaudeAgentsStore.shared
    /// Agente com o painel de log aberto.
    @State private var logOpen: String?

    var body: some View {
        // Relógio único da aba: as linhas recebem `now` em vez de cada uma ter o seu TimelineView.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let sessions = store.sessions.filter { Monitor.shared.showsMachine($0.host) }
        VStack(alignment: .leading, spacing: 6) {
            if sessions.isEmpty {
                EmptyState(symbol: "sparkles",
                           title: "Nenhum agente Claude em ação",
                           subtitle: "Sessões do Claude Code com subagentes nas últimas 2 h, ou com a conversa ativa nos últimos 15 min, aparecem aqui.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, session in
                        if idx > 0 {
                            Divider().padding(.horizontal, 8).opacity(0.5)
                        }
                        sessionBlock(session, now: now)
                    }
                }
                .padding(3)
            }
            if let id = logOpen, let agent = sessions.agent(id: id) {
                AgentLogPanel(agent: agent) { logOpen = nil }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
        }
        .onChange(of: sessions) { _, new in
            // Agente sumiu da lista: fecha o painel.
            if let id = logOpen, new.agent(id: id) == nil { logOpen = nil }
        }
    }

    // MARK: Sessão

    @ViewBuilder
    private func sessionBlock(_ session: ClaudeSession, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionHeader(session: session, now: now)
            if session.agents.isEmpty {
                Text("Só a conversa principal, sem subagentes.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 30)
                    .padding(.bottom, 7)
            } else {
                VStack(spacing: 0) {
                    ForEach(Self.rows(session.agents)) { row in
                        AgentRow(row: row,
                                 now: now,
                                 logOpen: logOpen == row.agent.id,
                                 onToggleLog: { toggleLog(row.agent.id) })
                    }
                }
                .padding(.bottom, 3)
            }
        }
    }

    private func toggleLog(_ id: String) {
        logOpen = logOpen == id ? nil : id
    }

    /// Achata a árvore (sempre expandida), guardando o que cada linha precisa para as linhas-guia.
    static func rows(_ roots: [ClaudeAgentNode]) -> [TreeRow] {
        var out: [TreeRow] = []
        func walk(_ nodes: [ClaudeAgentNode], level: Int, rails: [Bool]) {
            for (i, node) in nodes.enumerated() {
                let last = i == nodes.count - 1
                let open = !node.children.isEmpty
                out.append(TreeRow(agent: node, level: level, rails: rails, isLast: last, showsChildRail: open))
                if open { walk(node.children, level: level + 1, rails: level > 0 ? rails + [!last] : rails) }
            }
        }
        walk(roots, level: 0, rails: [])
        return out
    }
}

// MARK: - Modelo de linha

struct TreeRow: Identifiable {
    let agent: ClaudeAgentNode
    /// 0 = agente de nível 1 da sessão.
    let level: Int
    /// Colunas 0…level-2: o ancestral daquela coluna ainda tem irmãos abaixo → linha vertical contínua.
    let rails: [Bool]
    let isLast: Bool
    /// Nó com filhos: desce uma linha do ponto até o fim da linha.
    let showsChildRail: Bool
    var id: String { agent.id }
}

private enum Tree {
    static let step: CGFloat = 16
    /// x do ponto de estado dentro da linha (padding 8 + metade da coluna de 14).
    static let dotX: CGFloat = 15
    /// y do centro do ponto de estado.
    static let dotY: CGFloat = 15
    static func x(_ column: Int) -> CGFloat { CGFloat(column) * step + dotX }
}

// MARK: - Cabeçalho da sessão (fixo)

private struct SessionHeader: View {
    let session: ClaudeSession
    let now: Date
    @State private var copied = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(session.projectName)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            Chip(text: session.host ?? "Este Mac", symbol: session.host == nil ? "laptopcomputer" : "server.rack")
                .fixedSize()
                .opacity(Monitor.shared.hosts.isEmpty ? 0 : 1)
            Spacer(minLength: 4)
            if session.runningAgents > 0 {
                Chip(text: "\(session.runningAgents) rodando", tint: ClaudeAgentState.running.tint)
            }
            Text(ClaudeFmt.ago(session.lastActivityAt, now: now))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 52, alignment: .trailing)
            .help("Última atividade: " + session.lastActivityAt.formatted(date: .abbreviated, time: .standard))
            RowAction(symbol: copied ? "checkmark" : "doc.on.doc",
                      help: "Copiar ID da sessão") {
                ClaudeOpen.copy(session.id)
                copied = true
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .contextMenu {
            Button("Copiar ID da sessão", systemImage: "doc.on.doc") { ClaudeOpen.copy(session.id) }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
        }
    }
}

// MARK: - Linha de agente

private struct AgentRow: View {
    let row: TreeRow
    let now: Date
    let logOpen: Bool
    let onToggleLog: () -> Void
    @State private var hover = false
    @State private var copied = false

    private var agent: ClaudeAgentNode { row.agent }
    private var indent: CGFloat { CGFloat(row.level) * Tree.step }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RowDot(color: agent.state.tint)
                .padding(.top, 5)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(agent.description.isEmpty ? "(sem descrição)" : agent.description)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(agent.state == .done ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Chip(text: agent.agentType)
                        .layoutPriority(-1)
                }
                chips
            }

            Spacer(minLength: 4)

            actions
        }
        .padding(.leading, indent + 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(logOpen ? 0.08 : (hover ? 0.05 : 0)))
                .padding(.leading, indent)
        )
        .background(alignment: .topLeading) {
            TreeGuides(row: row)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onToggleLog)
        .contextMenu {
            Button(logOpen ? "Fechar log" : "Ver log", systemImage: "text.alignleft", action: onToggleLog)
            Button("Abrir transcript", systemImage: "doc.text") { ClaudeOpen.open(agent.transcriptURL) }
            Button("Mostrar no Finder", systemImage: "folder") { ClaudeOpen.reveal(agent.transcriptURL) }
            Divider()
            Button("Copiar ID do agente", systemImage: "doc.on.doc") { ClaudeOpen.copy(agent.id) }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
        }
    }

    private var chips: some View {
        HStack(spacing: 4) {
            Chip(text: agent.state.chipLabel, tint: agent.state.tint)
            LiveChip(text: Fmt.uptime(agent.runTime(now: now)), symbol: "clock", minWidth: 38)
            if agent.totalTokens > 0 {
                LiveChip(text: ClaudeFmt.tokens(agent.totalTokens), symbol: "circle.hexagongrid", minWidth: 30)
                    .help("\(agent.totalTokens.formatted()) tokens neste agente · \(agent.treeTokens.formatted()) com os filhos")
            }
            if let tool = agent.lastTool {
                Chip(text: tool, symbol: "wrench.and.screwdriver", mono: true)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Sempre visíveis, largura fixa.
    private var actions: some View {
        HStack(spacing: 0) {
            RowAction(symbol: "text.alignleft",
                      help: logOpen ? "Fechar log" : "Ver log embaixo da lista",
                      tint: logOpen ? .accentColor : .secondary,
                      action: onToggleLog)
            RowAction(symbol: "arrow.up.forward.square", help: "Abrir transcript") {
                ClaudeOpen.open(agent.transcriptURL)
            }
            RowAction(symbol: "folder", help: "Mostrar no Finder") {
                ClaudeOpen.reveal(agent.transcriptURL)
            }
            RowAction(symbol: copied ? "checkmark" : "doc.on.doc",
                      help: "Copiar ID do agente (\(agent.id))") {
                ClaudeOpen.copy(agent.id)
                copied = true
            }
        }
        .padding(.top, -2)
    }
}

// MARK: - Linhas-guia da árvore

private struct TreeGuides: View {
    let row: TreeRow

    var body: some View {
        Canvas { ctx, size in
            let color = GraphicsContext.Shading.color(.primary.opacity(0.16))
            let style = StrokeStyle(lineWidth: 1, lineCap: .round)
            var path = Path()

            // Ancestrais com irmãos abaixo: linha contínua.
            for (i, more) in row.rails.enumerated() where more {
                let x = Tree.x(i)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            // Cotovelo do próprio nó, vindo do pai.
            if row.level > 0 {
                let x = Tree.x(row.level - 1)
                let end = Tree.x(row.level) - 6
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: row.isLast ? Tree.dotY - 4 : size.height))
                if row.isLast {
                    path.addQuadCurve(to: CGPoint(x: x + 4, y: Tree.dotY),
                                      control: CGPoint(x: x, y: Tree.dotY))
                } else {
                    path.move(to: CGPoint(x: x, y: Tree.dotY))
                }
                path.addLine(to: CGPoint(x: end, y: Tree.dotY))
            }
            // Desce do ponto até os filhos.
            if row.showsChildRail {
                let x = Tree.x(row.level)
                path.move(to: CGPoint(x: x, y: Tree.dotY + 7))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            ctx.stroke(path, with: color, style: style)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Ponto de estado

/// Ponto de estado estático (sem pulso).
struct AgentDot: View {
    let state: ClaudeAgentState
    var size: CGFloat = 8

    var body: some View {
        RowDot(color: state.tint, size: size)
    }
}

// MARK: - Painel de log do agente (padrão do LogPanel)

private struct AgentLogPanel: View {
    let agent: ClaudeAgentNode
    let onClose: () -> Void
    @State private var text = ""
    @State private var loaded = false
    @State private var follow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(agent.description.isEmpty ? "Transcript" : agent.description)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Circle().fill(Status.running.color).frame(width: 5, height: 5)
                    .opacity(loaded && agent.state != .done ? 1 : 0)
                    .help("Atualizando a cada 2 s")
                Spacer(minLength: 4)
                Button { follow.toggle() } label: {
                    Image(systemName: follow ? "arrow.down.to.line" : "pause")
                }
                .buttonStyle(PillButtonStyle(tint: follow ? .accentColor : .secondary))
                .help(follow ? "Seguindo o fim" : "Rolagem livre")
                Button("Abrir") { ClaudeOpen.open(agent.transcriptURL) }
                    .buttonStyle(PillButtonStyle())
                Button("Finder") { ClaudeOpen.reveal(agent.transcriptURL) }
                    .buttonStyle(PillButtonStyle())
                RowAction(symbol: "xmark", help: "Fechar log", action: onClose)
            }
            .controlSize(.small)

            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !loaded {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Lendo transcript…").foregroundStyle(.secondary)
                            }
                        } else if text.isEmpty {
                            Text("Nada para mostrar ainda.").foregroundStyle(.secondary)
                        } else {
                            Text(text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 170)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .onChange(of: text) {
                    if follow { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: follow) { _, on in
                    if on { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .task(id: agent.id) {
            loaded = false
            while !Task.isCancelled {
                let new = await TranscriptTail.read(agent.transcriptURL, lines: 200)
                if Task.isCancelled { break }
                if new != text { text = new }
                loaded = true
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - Helpers

private enum ClaudeOpen {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

enum ClaudeFmt {
    /// 850 · 64,1k · 1,2M (vírgula decimal, pt-BR).
    static func tokens(_ n: Int) -> String {
        func short(_ v: Double, _ unit: String) -> String {
            let digits = v >= 100 ? 0 : 1
            let s = v.formatted(.number.precision(.fractionLength(0...digits)).locale(Locale(identifier: "pt_BR")))
            return s + unit
        }
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return short(Double(n) / 1_000, "k")
        default: return short(Double(n) / 1_000_000, "M")
        }
    }

    /// "agora", "há 42 s", "há 3 min", ou a hora (HH:mm) quando passa de 1 h.
    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 5 { return "agora" }
        if s < 60 { return "há \(s) s" }
        if s < 3600 { return "há \(s / 60) min" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

extension ClaudeAgentNode {
    /// Este nó e todos os descendentes.
    var treeSize: Int { 1 + children.reduce(0) { $0 + $1.treeSize } }
    var treeTokens: Int { totalTokens + children.reduce(0) { $0 + $1.treeTokens } }

    /// Tempo rodando: até agora se rodando; até a última atividade se terminou.
    func runTime(now: Date) -> TimeInterval {
        max(0, (state == .running ? now : lastActivityAt).timeIntervalSince(startedAt))
    }
}

extension Array where Element == ClaudeSession {
    /// Procura um agente em qualquer sessão/nível.
    func agent(id: String) -> ClaudeAgentNode? {
        func find(_ nodes: [ClaudeAgentNode]) -> ClaudeAgentNode? {
            for n in nodes {
                if n.id == id { return n }
                if let hit = find(n.children) { return hit }
            }
            return nil
        }
        for s in self { if let hit = find(s.agents) { return hit } }
        return nil
    }
}

extension ClaudeSession {
    var runningAgents: Int {
        func count(_ n: [ClaudeAgentNode]) -> Int {
            n.reduce(0) { $0 + ($1.state == .running ? 1 : 0) + count($1.children) }
        }
        return count(agents)
    }
}

extension ClaudeAgentState {
    var chipLabel: String {
        switch self {
        case .running: "rodando"
        case .done: "pronto"
        case .failed: "falhou"
        }
    }

    var tint: Color {
        switch self {
        case .running: Color(red: 0.36, green: 0.55, blue: 1.0)
        case .done: Status.running.color
        case .failed: Status.failed.color
        }
    }
}

/// Lê o fim de um transcript .jsonl do Claude Code e devolve texto legível.
enum TranscriptTail {
    static func read(_ url: URL, lines: Int) async -> String {
        await Task.detached(priority: .utility) { render(url, lines: lines) }.value
    }

    /// `window`: quantos bytes do fim são lidos (exposto para testes).
    static func render(_ url: URL, lines: Int, window: UInt64 = 512 * 1024) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? fh.readToEnd() else { return "" }
        // Decodificação tolerante: um corte no meio de um caractere UTF-8 vira U+FFFD em vez de zerar tudo.
        let raw = String(decoding: data, as: UTF8.self)
        var rows = raw.split(separator: "\n", omittingEmptySubsequences: false)
        // Janela cortada: a primeira linha é parcial (e pode conter o caractere quebrado).
        if size > window, !rows.isEmpty { rows.removeFirst() }
        var out: [String] = []
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for row in rows {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
                  let msg = obj["message"] as? [String: Any] else { continue }
            let role = (msg["role"] as? String) ?? (obj["type"] as? String) ?? "?"
            let stamp = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }.map { $0.formatted(time) + " " } ?? ""
            func add(_ tag: String, _ text: String) {
                let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                guard !flat.isEmpty else { return }
                out.append("\(stamp)\(tag) \(flat.count > 240 ? String(flat.prefix(240)) + "…" : flat)")
            }
            if let text = msg["content"] as? String {
                add(role == "user" ? "›" : "‹", text)
            } else if let parts = msg["content"] as? [[String: Any]] {
                for part in parts {
                    switch part["type"] as? String {
                    case "text": add(role == "user" ? "›" : "‹", part["text"] as? String ?? "")
                    case "tool_use":
                        let name = part["name"] as? String ?? "tool"
                        let input = part["input"] as? [String: Any] ?? [:]
                        let hint = ["description", "command", "file_path", "pattern", "prompt"]
                            .lazy.compactMap { input[$0] as? String }.first ?? ""
                        add("⚙ \(name)", hint)
                    case "tool_result":
                        let err = (part["is_error"] as? Bool) == true
                        let body: String
                        if let s = part["content"] as? String { body = s }
                        else if let a = part["content"] as? [[String: Any]] { body = a.compactMap { $0["text"] as? String }.joined(separator: " ") }
                        else { body = "" }
                        add(err ? "✗" : "↳", body)
                    default: break
                    }
                }
            }
        }
        return out.suffix(lines).joined(separator: "\n")
    }
}
