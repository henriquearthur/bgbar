import SwiftUI

/// Página "Máquinas SSH": substitui as abas (com "Voltar"), como o detalhe.
struct HostsView: View {
    let onBack: () -> Void
    private let monitor = Monitor.shared
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
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
                Label("Máquinas SSH", systemImage: "network")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, UI.pad - 2)
            .padding(.vertical, 8)
            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Card { list }
                    HStack(spacing: 6) {
                        TextField("alias do ~/.ssh/config ou usuário@host", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .autocorrectionDisabled()
                            .onSubmit(add)
                        Button("Conectar", action: add)
                            .buttonStyle(PillButtonStyle(tint: .accentColor, prominent: true))
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Máquinas Linux acessadas pelo ssh do sistema, sem interação: a autenticação precisa funcionar por chave ou agente (teste com `ssh -o BatchMode=yes <destino> true`). Aparecem nas mesmas abas os serviços systemd do usuário, os containers Docker e os processos de dev de cada máquina.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(UI.pad)
            }
            .frame(maxHeight: .infinity)
        }
        .onExitCommand(perform: onBack)
    }

    @ViewBuilder
    private var list: some View {
        if monitor.hosts.isEmpty {
            EmptyState(symbol: "network.slash", title: "Nenhuma máquina conectada",
                       subtitle: "Adicione um destino ssh abaixo para ver o segundo plano dele aqui.")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(monitor.hosts.enumerated()), id: \.element) { idx, host in
                    if idx > 0 {
                        Divider().padding(.leading, 28).opacity(0.5)
                    }
                    row(host)
                }
            }
            .padding(3)
        }
    }

    private func row(_ host: String) -> some View {
        let state = monitor.remote[host]
        let online = state?.online ?? false
        let checked = state?.checked ?? false
        let color = !checked ? Status.starting.color : (online ? Status.running.color : Status.failed.color)
        return HStack(alignment: .top, spacing: 9) {
            RowDot(color: color)
                .padding(.top, 5)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(host)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status(state))
                    .font(.system(size: 10.5))
                    .foregroundStyle(checked && !online ? Status.failed.color : Color.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            IconButton(symbol: "trash", help: "Remover \(host)") { monitor.removeHost(host) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func status(_ state: Monitor.RemoteHost?) -> String {
        guard let state, state.checked else { return "conectando…" }
        guard state.online else { return state.error ?? "fora do ar" }
        let up = state.items.filter { $0.status.isUp || $0.status == .unhealthy }.count
        let name = state.hostname.map { " · \($0)" } ?? ""
        return "conectado · \(up) rodando de \(state.items.count)\(name)"
    }

    private func add() {
        let host = draft.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if let error = monitor.addHost(host) {
            monitor.toast = error
        } else {
            draft = ""
        }
    }
}
