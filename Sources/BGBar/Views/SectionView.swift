import SwiftUI

/// Conteúdo de uma aba de `Kind`: cartão com as linhas, sem cabeçalho nem colapso.
struct SectionView: View {
    let kind: Kind
    let onSelect: (Item) -> Void
    private let monitor = Monitor.shared
    @AppStorage(DockerFilter.showStoppedKey) private var showStopped = false

    var body: some View {
        let items = DockerFilter.visible(kind, showStopped: showStopped)
        let groups = machineGroups(items)
        VStack(alignment: .leading, spacing: 6) {
            if groups.count > 0 {
                ForEach(groups, id: \.title) { group in
                    MachineHeader(title: group.title, remote: group.remote, items: group.items)
                    Card { rows(group.items) }
                }
            } else {
                Card {
                    content(items)
                }
            }
            let stopped = monitor.items(kind).count - items.count
            if stopped > 0 {
                Text("\(stopped) parado\(stopped == 1 ? "" : "s") · mostre em ⋯ › Mostrar containers parados")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            let hidden = monitor.hiddenCount(kind)
            if hidden > 0, !monitor.showHidden {
                Text("\(hidden) oculto\(hidden == 1 ? "" : "s") · mostre em ⋯ › Mostrar ocultos")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func content(_ items: [Item]) -> some View {
        if kind == .docker && !monitor.dockerAvailable && items.isEmpty {
            EmptyState(symbol: "shippingbox.and.arrow.backward",
                       title: "Docker não está respondendo",
                       subtitle: "Abra o OrbStack ou o Docker Desktop; tento de novo sozinho.")
        } else if items.isEmpty {
            EmptyState(symbol: emptySymbol, title: emptyTitle, subtitle: emptySubtitle)
        } else {
            rows(items)
        }
    }

    private func rows(_ items: [Item]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                if idx > 0 {
                    Divider().padding(.leading, 28).opacity(0.5)
                }
                ItemRow(item: item) { onSelect(item) }
            }
        }
        .padding(3)
    }

    /// Com máquinas remotas e o filtro em "Todas", a lista vem separada por máquina
    /// (este Mac primeiro), cada uma com seu cabeçalho. Vazio = lista única, sem cabeçalho.
    private func machineGroups(_ items: [Item]) -> [(title: String, remote: Bool, items: [Item])] {
        guard !monitor.hosts.isEmpty, monitor.machine.isEmpty, !items.isEmpty else { return [] }
        let machines: [String?] = [nil] + monitor.hosts.map { Optional($0) }
        return machines.compactMap { host in
            let own = items.filter { $0.host == host }
            return own.isEmpty ? nil : (host ?? "Este Mac", host != nil, own)
        }
    }

    private var emptySymbol: String {
        switch kind {
        case .agent: "moon.zzz"
        case .docker: "shippingbox"
        case .dev: "cup.and.saucer"
        }
    }
    private var emptyTitle: String {
        switch kind {
        case .agent: "Nenhum LaunchAgent seu"
        case .docker: "Nenhum container"
        case .dev: "Nada de dev rodando"
        }
    }
    private var emptySubtitle: String {
        switch kind {
        case .agent: "Agentes em ~/Library/LaunchAgents aparecem aqui."
        case .docker: "Containers do OrbStack/Docker aparecem aqui."
        case .dev: "bun, node, python e afins aparecem quando subirem."
        }
    }
}

/// Cabeçalho de um grupo de máquina na lista.
private struct MachineHeader: View {
    let title: String
    let remote: Bool
    let items: [Item]

    var body: some View {
        let up = items.filter { $0.status.isUp || $0.status == .unhealthy }.count
        HStack(spacing: 5) {
            Image(systemName: remote ? "server.rack" : "laptopcomputer")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(up)/\(items.count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}

/// Containers parados ficam escondidos por padrão (⋯ › Mostrar containers parados).
@MainActor
enum DockerFilter {
    static let showStoppedKey = "showStoppedContainers"

    /// Itens visíveis da aba. Container parado (exited/created/dead) sai da lista, exceto
    /// fixados: esses contam como problema quando caem, então continuam à vista.
    static func visible(_ kind: Kind, showStopped: Bool) -> [Item] {
        let monitor = Monitor.shared
        let items = monitor.items(kind)
        guard kind == .docker, !showStopped else { return items }
        return items.filter { i in
            i.status.isUp || i.status == .unhealthy || i.status == .restarting || monitor.isPinned(i)
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}
