import SwiftUI

@main
struct BGBarApp: App {
    init() {
        Monitor.shared.start()
        ClaudeAgentsStore.shared.start()
        Notifier.shared.requestAuthorization()
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Ícone da barra: observa `Monitor.shared.health` e troca a imagem (cacheada).
private struct MenuBarLabel: View {
    private let monitor = Monitor.shared
    @ObservedObject private var claude = ClaudeAgentsStore.shared

    var body: some View {
        let agents = claude.runningCount
        // Uma imagem só (ícone + número): HStack no rótulo do MenuBarExtra não renderiza direito.
        Image(nsImage: StatusIcon.image(for: monitor.overallHealth, count: agents))
            .accessibilityLabel(agents > 0 ? "BGBar, \(agents) agentes Claude rodando" : "BGBar")
    }
}
