import SwiftUI

/// Linha compacta de um item na lista, com as ações sempre visíveis à direita.
///
/// Layout estável: nada aqui anima, os slots de ação têm largura fixa (slot sem ação
/// fica vazio, mantendo as colunas alinhadas entre linhas) e números ao vivo usam
/// dígitos monoespaçados com largura mínima.
struct ItemRow: View {
    let item: Item
    let onOpen: () -> Void
    private let monitor = Monitor.shared
    @State private var hover = false
    /// Ação destrutiva armada: o segundo clique no mesmo botão confirma.
    @State private var armed: Slot?
    /// Ação disparada por esta linha (para pôr o spinner no slot certo).
    @State private var running: Slot?
    /// Abertura de log em andamento (é async e não passa pelo `busy` do Monitor).
    @State private var logBusy: Slot?
    /// Ação destrutiva pedida pelo menu de contexto, aguardando confirmação.
    @State private var menuConfirm: Actions.Op?

    var body: some View {
        let busy = monitor.busy.contains(item.id)
        let pinned = monitor.isPinned(item)
        let hidden = monitor.isHidden(item)

        // Os chips ficam abaixo, na largura inteira da linha (a coluna de ações só ocupa
        // a altura de nome + detalhe), alinhados ao texto.
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .top, spacing: 9) {
            RowDot(color: item.status.color, glow: item.status != .stopped && item.status != .notLoaded)
                .padding(.top, 5)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .italic(item.isGhost)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.orange.opacity(0.85))
                            .rotationEffect(.degrees(35))
                    }
                    if hidden {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .opacity(hidden ? 0.5 : (item.isGhost ? 0.6 : 1))

            Spacer(minLength: 4)

            actions(busy: busy)
                .padding(.top, 1)
          }
          chips
            .padding(.leading, 23)
            .opacity(hidden ? 0.5 : (item.isGhost ? 0.6 : 1))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            ItemMenu(item: item, onOpen: onOpen) { menuConfirm = $0 }
        }
        .confirmDestructive($menuConfirm, on: item)
        .onChange(of: busy) { _, b in
            if b { armed = nil } else { running = nil }
        }
        .task(id: armed) {
            // Confirmação desarma sozinha.
            guard armed != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { armed = nil }
        }
    }

    /// Mostra quantas portas couberem (3, 1 ou nenhuma). A última opção pode truncar o
    /// status, mas nunca força a largura da lista: o que sobrar é cortado na própria linha.
    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            chipRow(ports: 3)
            chipRow(ports: 1)
            chipRow(ports: 0)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
    }

    private func chipRow(ports shown: Int) -> some View {
        HStack(spacing: 4) {
            // Container rodando: a nota do Docker ("Up 2 hours") só repete o chip de uptime.
            if item.status != .running || (item.statusNote != nil && item.kind != .docker) {
                Chip(text: item.chipStatusText, tint: item.status == .stopped || item.status == .notLoaded ? nil : item.status.color)
            }
            if let up = item.uptime {
                LiveChip(text: Fmt.uptime(up), symbol: "clock", minWidth: 38)
            }
            if let cpu = item.cpu, item.status.isUp || item.status == .unhealthy {
                LiveChip(text: Fmt.cpu(cpu), symbol: "cpu", minWidth: 32, tint: cpu >= 80 ? Status.restarting.color : nil)
            }
            if let mem = item.memBytes, item.status.isUp || item.status == .unhealthy {
                LiveChip(text: Fmt.memory(mem), symbol: "memorychip", minWidth: 40)
            }
            ForEach(item.ports.prefix(shown), id: \.self) { PortChip(port: $0, host: item.host) }
            if item.ports.count > shown {
                Chip(text: "+\(item.ports.count - shown)")
                    .help(item.ports.map { ":\($0)" }.joined(separator: " "))
            }
            if let pid = item.pid, item.ports.count < 2, shown > 0 {
                Chip(text: "\(pid)", symbol: "number", mono: true)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Ações

    /// Colunas fixas de ação. A ordem é a mesma em todas as linhas.
    enum Slot: Hashable { case power, restart, kill, log, finder }

    private func actions(busy: Bool) -> some View {
        HStack(spacing: 0) {
            powerSlot(busy: busy)
            slot(.restart, show: Actions.canRestart(item) && (item.status.isUp || item.status == .unhealthy), busy: busy) {
                RowAction(symbol: "arrow.clockwise",
                          help: armed == .restart ? "Clique de novo para reiniciar \(item.name)" : "Reiniciar",
                          armed: armed == .restart, disabled: busy) { destructive(.restart, op: .restart) }
            }
            slot(.kill, show: Actions.canKill(item), busy: busy) {
                RowAction(symbol: "xmark.octagon",
                          help: armed == .kill ? "Clique de novo para enviar SIGTERM ao PID \(item.pid.map(String.init) ?? "?")" : "Encerrar processo (SIGTERM)",
                          armed: armed == .kill, disabled: busy) { destructive(.kill, op: .kill(force: false)) }
            }
            slot(.log, show: Actions.hasLog(item), busy: false) {
                RowAction(symbol: "doc.text", help: "Ver log no Console") { openLog(.log, in: .console) }
            }
            slot(.finder, show: Actions.hasLog(item), busy: false) {
                RowAction(symbol: "folder", help: "Mostrar log no Finder") { openLog(.finder, in: .finder) }
            }
        }
    }

    /// Iniciar ou parar (mutuamente exclusivos), no mesmo slot.
    private func powerSlot(busy: Bool) -> some View {
        // Ocupado por ação vinda de fora da linha (detalhe, menu): spinner no primeiro slot.
        let external = busy && running == nil
        return Group {
            if external || (busy && running == .power) || logBusy == .power {
                RowSpinner()
            } else if Actions.canStop(item) {
                RowAction(symbol: "stop.fill",
                          help: armed == .power ? "Clique de novo para parar \(item.name)" : "Parar",
                          armed: armed == .power, disabled: busy) { destructive(.power, op: .stop) }
            } else if Actions.canStart(item) {
                RowAction(symbol: "play.fill", help: "Iniciar", tint: Status.running.color, disabled: busy) {
                    running = .power
                    Actions.run(.start, on: item)
                }
            } else {
                RowSlotSpacer()
            }
        }
    }

    @ViewBuilder
    private func slot<B: View>(_ s: Slot, show: Bool, busy: Bool, @ViewBuilder button: () -> B) -> some View {
        if (busy && running == s) || logBusy == s {
            RowSpinner()
        } else if show {
            button()
        } else {
            RowSlotSpacer()
        }
    }

    /// Primeiro clique arma, segundo executa.
    private func destructive(_ s: Slot, op: Actions.Op) {
        if armed == s {
            armed = nil
            running = s
            Actions.run(op, on: item)
        } else {
            armed = s
        }
    }

    private func openLog(_ s: Slot, in app: Actions.LogApp) {
        guard logBusy == nil else { return }
        logBusy = s
        Task {
            await Actions.openLog(item, in: app)
            logBusy = nil
        }
    }
}

// MARK: - Peças de linha (sem animação, tamanho fixo)

enum RowMetrics {
    /// Lado de cada slot de ação.
    static let slot: CGFloat = 22
}

/// Botão de ícone de linha: largura fixa, hover só muda cor, sem animação.
/// `armed` pinta de vermelho (estado "clique de novo para confirmar").
struct RowAction: View {
    let symbol: String
    var help: String = ""
    var tint: Color = .secondary
    var armed = false
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: armed ? "checkmark" : symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(armed ? Color.white : (hover ? Color.primary : tint))
                .frame(width: RowMetrics.slot, height: RowMetrics.slot)
                .background(
                    Circle().fill(armed ? Status.failed.color : Color.primary.opacity(hover ? 0.1 : 0))
                        .padding(1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Spinner com o mesmo tamanho de um `RowAction`.
struct RowSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: RowMetrics.slot, height: RowMetrics.slot)
    }
}

/// Slot vazio: mantém as colunas de ação alinhadas.
struct RowSlotSpacer: View {
    var body: some View {
        Color.clear.frame(width: RowMetrics.slot, height: RowMetrics.slot)
    }
}

/// Ponto de estado estático (sem pulso).
struct RowDot: View {
    let color: Color
    var glow = true
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .shadow(color: glow ? color.opacity(0.6) : .clear, radius: 2.5)
            Circle()
                .strokeBorder(.white.opacity(glow ? 0.25 : 0), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
    }
}

/// Chip para valor ao vivo: dígitos monoespaçados e largura mínima, para não "pular".
struct LiveChip: View {
    var text: String
    var symbol: String? = nil
    var minWidth: CGFloat
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize() // valor curto: nunca trunca (o excesso da linha é cortado em `chips`)
                .frame(minWidth: minWidth, alignment: .leading)
        }
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous).fill((tint ?? .primary).opacity(tint == nil ? 0.06 : 0.13))
        )
    }
}

/// Menu de contexto com todas as ações (reaproveitado no detalhe se preciso).
/// Num menu não dá para usar o segundo clique: parar, reiniciar e encerrar passam por
/// `confirm`, e quem hospeda o menu mostra a confirmação (`confirmDestructive`).
struct ItemMenu: View {
    let item: Item
    var onOpen: (() -> Void)? = nil
    let confirm: (Actions.Op) -> Void
    private let monitor = Monitor.shared

    var body: some View {
        if let onOpen {
            Button("Ver detalhes", systemImage: "info.circle", action: onOpen)
            Divider()
        }
        if Actions.canStart(item) {
            Button("Iniciar", systemImage: "play.fill") { Actions.run(.start, on: item) }
        }
        if Actions.canStop(item) {
            Button("Parar…", systemImage: "stop.fill") { confirm(.stop) }
        }
        if Actions.canRestart(item) {
            Button("Reiniciar…", systemImage: "arrow.clockwise") { confirm(.restart) }
        }
        if Actions.canKill(item) {
            Menu("Encerrar processo") {
                Button("SIGTERM…") { confirm(.kill(force: false)) }
                Button("SIGKILL (forçar)…") { confirm(.kill(force: true)) }
            }
        }
        Divider()
        if !item.ports.isEmpty {
            Menu("Abrir porta") {
                ForEach(item.ports, id: \.self) { p in
                    Button("\(Actions.portHost(item.host)):\(String(p))") { Actions.openPort(p, host: item.host) }
                }
            }
        }
        if Actions.hasLog(item) {
            Menu("Abrir log") {
                Button("No Console") { Task { await Actions.openLog(item, in: .console) } }
                Button("No editor") { Task { await Actions.openLog(item, in: .editor) } }
                Button("No Finder") { Task { await Actions.openLog(item, in: .finder) } }
            }
        }
        if item.pid != nil {
            Button("Copiar PID", systemImage: "doc.on.doc") { Actions.copyPID(item) }
        }
        Divider()
        Button(monitor.isPinned(item) ? "Desafixar" : "Fixar",
               systemImage: monitor.isPinned(item) ? "pin.slash" : "pin") { monitor.togglePin(item) }
        Button(monitor.isHidden(item) ? "Mostrar" : "Ocultar",
               systemImage: monitor.isHidden(item) ? "eye" : "eye.slash") { monitor.toggleHidden(item) }
    }
}

// MARK: - Confirmação de ação destrutiva (menus)

extension View {
    /// Pede confirmação de `pending` (vindo de um menu) antes de chamar `Actions.run`.
    func confirmDestructive(_ pending: Binding<Actions.Op?>, on item: Item) -> some View {
        let op = pending.wrappedValue
        return confirmationDialog(
            op.map { $0.confirmTitle(item) } ?? "",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: op
        ) { op in
            Button(op.confirmButton, role: .destructive) { Actions.run(op, on: item) }
            Button("Cancelar", role: .cancel) {}
        }
    }
}

extension Actions.Op {
    func confirmTitle(_ item: Item) -> String {
        let pid = item.pid.map(String.init) ?? "?"
        switch self {
        case .start: return "Iniciar \(item.name)?"
        case .stop: return "Parar \(item.name)?"
        case .restart: return "Reiniciar \(item.name)?"
        case .kill(false): return "Enviar SIGTERM ao PID \(pid) (\(item.name))?"
        case .kill(true): return "Enviar SIGKILL ao PID \(pid) (\(item.name))? O processo não tem chance de limpar."
        }
    }

    var confirmButton: String {
        switch self {
        case .start: "Iniciar"
        case .stop: "Parar"
        case .restart: "Reiniciar"
        case .kill(false): "Enviar SIGTERM"
        case .kill(true): "Forçar SIGKILL"
        }
    }
}
