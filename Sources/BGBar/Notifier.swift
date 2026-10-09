import Foundation
import UserNotifications

/// Notificações de queda via UserNotifications.
/// Sem bundle (ex.: `swift run`) o UNUserNotificationCenter crasha, então tudo vira no-op.
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()

    private var enabled = false
    private var lastSent: [String: Date] = [:]
    private let minInterval: TimeInterval = 60
    /// Limite global: no máximo `burstLimit` avisos por minuto; o excedente vira um resumo.
    private var recent: [Date] = []
    private var suppressedInBurst: [String] = []
    private var summaryTask: Task<Void, Never>?
    private let burstLimit = 4

    private override init() { super.init() }

    /// Chamado uma vez no início do app.
    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil, !enabled else { return }
        enabled = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `item` é o estado novo (caído); `previous` o estado anterior (no ar).
    func notifyDown(_ item: Item, previous: Item) {
        guard enabled else { return }
        let now = Date()
        if let last = lastSent[item.key], now.timeIntervalSince(last) < minInterval { return }
        lastSent[item.key] = now
        lastSent = lastSent.filter { now.timeIntervalSince($0.value) < minInterval }
        recent = recent.filter { now.timeIntervalSince($0) < 60 }

        guard recent.count < burstLimit else {
            // Rajada (ex.: Docker reiniciou tudo): junta o resto num resumo único.
            suppressedInBurst.append(item.name)
            scheduleSummary()
            return
        }
        recent.append(now)
        post(id: "down-\(item.key)-\(Int(now.timeIntervalSince1970))", title: title(item),
             body: body(item, previous: previous), thread: item.kind.rawValue)
    }

    private func scheduleSummary() {
        guard summaryTask == nil else { return }
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self else { return }
            let names = self.suppressedInBurst
            self.suppressedInBurst = []
            self.summaryTask = nil
            guard !names.isEmpty else { return }
            let shown = names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " e mais \(names.count - 5)" : "")
            self.post(id: "down-burst-\(Int(Date().timeIntervalSince1970))",
                      title: "Mais \(names.count) \(names.count == 1 ? "item caiu" : "itens caíram")",
                      body: shown, thread: "burst")
        }
    }

    private func post(id: String, title: String, body: String, thread: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func title(_ item: Item) -> String {
        switch item.status {
        case .unhealthy: "\(item.name) ficou unhealthy"
        case .restarting: "\(item.name) está reiniciando"
        case .failed: "\(item.name) falhou"
        case .notLoaded: "\(item.name) foi descarregado"
        default: "\(item.name) caiu"
        }
    }

    private func body(_ item: Item, previous: Item) -> String {
        let kind: String = switch item.kind {
        case .agent: "LaunchAgent"
        case .docker: "Docker"
        case .dev: "Processo de dev"
        }
        var parts = [item.host.map { "\(item.kindTitle) em \($0)" } ?? kind, item.status.label]
        if let note = item.statusNote, !note.isEmpty {
            parts.append(note)
        } else if let code = item.exitCode {
            parts.append("exit \(code)")
        }
        if let up = previous.uptime { parts.append("estava no ar há \(Fmt.uptime(up))") }
        return parts.joined(separator: " · ")
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Mostra banner mesmo com o app em primeiro plano.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
