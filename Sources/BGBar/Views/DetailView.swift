import SwiftUI

/// Página de detalhe dentro do popover: substitui as abas (com "Voltar") na mesma área de altura fixa.
struct DetailView: View {
    let initial: Item
    let onBack: () -> Void
    private let monitor = Monitor.shared
    @State private var killConfirm = false
    /// Parar/reiniciar armado: o segundo clique no mesmo botão confirma (desarma em 4 s).
    @State private var armed: Actions.Op?
    /// Ação destrutiva pedida pelo menu ⋯, aguardando confirmação.
    @State private var menuConfirm: Actions.Op?

    /// Estado ao vivo (ou o último conhecido, se o item sumiu da lista).
    private var item: Item { monitor.item(id: initial.id) ?? gone }
    private var gone: Item {
        var i = initial
        i.status = .stopped
        i.statusNote = "não está mais na lista"
        i.pid = nil
        i.cpu = nil
        i.memBytes = nil
        i.ports = []
        return i
    }

    var body: some View {
        let item = self.item
        VStack(spacing: 0) {
            topBar(item)
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    hero(item)
                    actionBar(item)
                    infoGrid(item)
                    if Actions.hasLog(item) {
                        LogPanel(item: item)
                    }
                }
                .padding(UI.pad)
            }
            // Ocupa a mesma área fixa da lista (UI.bodyHeight): abrir o detalhe não redimensiona o popover.
            .frame(maxHeight: .infinity)
        }
        .onExitCommand(perform: onBack)
        .confirmDestructive($menuConfirm, on: item)
        .onChange(of: monitor.busy.contains(item.id)) { _, b in if b { armed = nil } }
        .task(id: armed) {
            guard armed != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { armed = nil }
        }
    }

    // MARK: Barra superior

    private func topBar(_ item: Item) -> some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Voltar").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()
            Label(item.kindTitle, systemImage: item.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Menu {
                ItemMenu(item: item) { menuConfirm = $0 }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, UI.pad - 2)
        .padding(.vertical, 8)
    }

    // MARK: Cabeçalho do item

    private func hero(_ item: Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(item.status.color.opacity(0.14))
                StatusDot(status: item.status, size: 12)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .italic(item.isGhost)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if monitor.isPinned(item) {
                        Image(systemName: "pin.fill").font(.system(size: 10))
                            .foregroundStyle(.orange.opacity(0.85)).rotationEffect(.degrees(35))
                    }
                }
                HStack(spacing: 5) {
                    Text(item.chipStatusText.capitalizedFirst)
                        .foregroundStyle(item.status == .stopped || item.status == .notLoaded ? Color.secondary : item.status.color)
                        .fontWeight(.medium)
                    if let up = item.uptime {
                        Text("· há \(Fmt.uptime(up))").foregroundStyle(.secondary)
                    }
                    if monitor.busy.contains(item.id) {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.system(size: 11.5))
                .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Ações

    private func actionBar(_ item: Item) -> some View {
        let busy = monitor.busy.contains(item.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if Actions.canStart(item) {
                    Button { Actions.run(.start, on: item) } label: { Label("Iniciar", systemImage: "play.fill") }
                        .buttonStyle(PillButtonStyle(tint: Status.running.color, prominent: true))
                }
                if Actions.canStop(item) {
                    armedButton(.stop, "Parar", symbol: "stop.fill", item: item)
                }
                if Actions.canRestart(item) {
                    armedButton(.restart, "Reiniciar", symbol: "arrow.clockwise", item: item)
                }
                Spacer(minLength: 0)
                Button { monitor.togglePin(item) } label: {
                    Image(systemName: monitor.isPinned(item) ? "pin.slash" : "pin")
                }
                .buttonStyle(PillButtonStyle())
                .help(monitor.isPinned(item) ? "Desafixar" : "Fixar no topo e avisar se cair")
                Button { monitor.toggleHidden(item) } label: {
                    Image(systemName: monitor.isHidden(item) ? "eye" : "eye.slash")
                }
                .buttonStyle(PillButtonStyle())
                .help(monitor.isHidden(item) ? "Mostrar na lista" : "Ocultar da lista")
            }
            .disabled(busy)

            if Actions.canKill(item) {
                killRow(item)
                    .disabled(busy)
            }
        }
    }

    /// Mesmo padrão do `ItemRow`: o primeiro clique arma (ícone vira ✓ e fica vermelho,
    /// texto igual para não mudar a largura), o segundo executa.
    private func armedButton(_ op: Actions.Op, _ title: String, symbol: String, item: Item) -> some View {
        let isArmed = armed == op
        return Button {
            if isArmed {
                armed = nil
                Actions.run(op, on: item)
            } else {
                armed = op
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: isArmed ? "checkmark" : symbol).frame(width: 12)
            }
        }
        .buttonStyle(PillButtonStyle(tint: isArmed ? Status.failed.color : .primary, prominent: isArmed))
        .help(isArmed ? "Clique de novo para \(title.lowercased()) \(item.name)" : title)
    }

    @ViewBuilder
    private func killRow(_ item: Item) -> some View {
        HStack(spacing: 6) {
            if killConfirm {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Status.failed.color)
                    .font(.system(size: 11))
                Text("Enviar SIGTERM?")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
                Button("Cancelar") { killConfirm = false }
                    .buttonStyle(PillButtonStyle(tint: .secondary))
                Button("SIGKILL") {
                    killConfirm = false
                    Actions.run(.kill(force: true), on: item)
                }
                .buttonStyle(PillButtonStyle(tint: Status.failed.color))
                .help("Forçar (não dá chance de o processo limpar)")
                Button("Confirmar") {
                    killConfirm = false
                    Actions.run(.kill(force: false), on: item)
                }
                .buttonStyle(PillButtonStyle(tint: Status.failed.color, prominent: true))
            } else {
                Button {
                    killConfirm = true
                } label: {
                    Label("Encerrar processo\(item.pid.map { " \($0)" } ?? "")", systemImage: "xmark.octagon")
                }
                .buttonStyle(PillButtonStyle(tint: Status.failed.color))
                Spacer(minLength: 0)
            }
        }
        .padding(killConfirm ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Status.failed.color.opacity(killConfirm ? 0.08 : 0))
        )
        .task(id: killConfirm) {
            // Volta sozinho se ficar parado esperando.
            guard killConfirm else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { killConfirm = false }
        }
    }

    // MARK: Grade de infos

    private func infoGrid(_ item: Item) -> some View {
        Card {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                if let host = item.host { row("Máquina") { mono(host) } }
                row("Estado") {
                    HStack(spacing: 5) {
                        StatusDot(status: item.status, size: 6)
                        Text(item.chipStatusText)
                        if let code = item.exitCode, item.status != .failed {
                            Text("· saída \(code)").foregroundStyle(.secondary)
                        }
                    }
                }
                if let pid = item.pid {
                    row("PID") {
                        HStack(spacing: 4) {
                            Text(String(pid)).font(.system(size: 11.5, design: .monospaced))
                            IconButton(symbol: "doc.on.doc", help: "Copiar PID", size: 18) {
                                Actions.copyPID(item)
                            }
                        }
                    }
                }
                if let up = item.uptime { row("Ativo há") { Text(Fmt.uptime(up)).monospacedDigit() } }
                if let cpu = item.cpu { row("CPU") { Text(Fmt.cpu(cpu)).monospacedDigit() } }
                if let mem = item.memBytes { row("Memória") { Text(Fmt.memory(mem)).monospacedDigit() } }
                if !item.ports.isEmpty {
                    row("Portas") {
                        HStack(spacing: 4) { ForEach(item.ports, id: \.self) { PortChip(port: $0, host: item.host) } }
                    }
                }
                if let label = item.label { row(item.host == nil ? "Label" : "Unit") { mono(label) } }
                if let plist = item.plistPath { row(item.host == nil ? "Plist" : "Arquivo") { mono(Fmt.abbreviateHome(plist)) } }
                if let cid = item.containerID { row("Container") { mono(String(cid.prefix(12))) } }
                if item.kind == .docker, !item.detail.isEmpty { row("Imagem") { mono(item.detail) } }
                if let group = item.group { row(item.kind == .docker ? "Projeto" : "Grupo") { Text(group) } }
                if let dir = item.workingDir { row("Diretório") { mono(Fmt.abbreviateHome(dir)) } }
                if let cmd = item.command, !cmd.isEmpty {
                    row("Comando") {
                        Text(cmd)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(6)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(item.logPaths.enumerated()), id: \.offset) { idx, p in
                    row(idx == 0 ? "Logs" : "") { mono(Fmt.abbreviateHome(p)) }
                }
            }
            .font(.system(size: 11.5))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row<V: View>(_ title: String, @ViewBuilder _ value: () -> V) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mono(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10.5, design: .monospaced))
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
