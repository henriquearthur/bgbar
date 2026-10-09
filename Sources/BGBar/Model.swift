import SwiftUI

enum Kind: String, CaseIterable, Identifiable, Sendable {
    case agent, docker, dev
    var id: String { rawValue }

    var title: String {
        switch self {
        case .agent: "LaunchAgents"
        case .docker: "Docker"
        case .dev: "Processos de dev"
        }
    }

    var symbol: String {
        switch self {
        case .agent: "gearshape.2"
        case .docker: "shippingbox"
        case .dev: "terminal"
        }
    }
}

enum Status: Sendable, Equatable {
    case running, starting, restarting, unhealthy, failed, stopped, notLoaded

    var label: String {
        switch self {
        case .running: "rodando"
        case .starting: "iniciando"
        case .restarting: "reiniciando"
        case .unhealthy: "unhealthy"
        case .failed: "falhou"
        case .stopped: "parado"
        case .notLoaded: "não carregado"
        }
    }

    var color: Color {
        switch self {
        case .running: Color(red: 0.20, green: 0.78, blue: 0.42)
        case .starting, .restarting: Color(red: 1.0, green: 0.62, blue: 0.10)
        case .unhealthy, .failed: Color(red: 1.0, green: 0.30, blue: 0.27)
        case .stopped, .notLoaded: Color.secondary.opacity(0.55)
        }
    }

    /// Considera "no ar" (para detectar quedas).
    var isUp: Bool { self == .running || self == .starting }
    var isTransient: Bool { self == .starting || self == .restarting }
}

enum Health: Sendable {
    case ok, warning, critical

    var color: Color {
        switch self {
        case .ok: Status.running.color
        case .warning: Status.restarting.color
        case .critical: Status.failed.color
        }
    }

    var nsColor: NSColor {
        switch self {
        case .ok: NSColor(red: 0.20, green: 0.78, blue: 0.42, alpha: 1)
        case .warning: NSColor(red: 1.0, green: 0.62, blue: 0.10, alpha: 1)
        case .critical: NSColor(red: 1.0, green: 0.30, blue: 0.27, alpha: 1)
        }
    }
}

struct Item: Identifiable, Sendable, Equatable {
    /// Único na lista atual.
    var id: String
    /// Chave estável para fixar/ocultar (sobrevive a reinícios e PIDs novos).
    var key: String
    var kind: Kind
    var name: String
    var detail: String
    var group: String?
    var status: Status
    var statusNote: String?
    var pid: Int32?
    var startedAt: Date?
    var cpu: Double?
    var memBytes: UInt64?
    var ports: [Int] = []
    var logPaths: [String] = []
    var exitCode: Int?
    // específicos
    var label: String?
    var plistPath: String?
    var containerID: String?
    var workingDir: String?
    var command: String?
    /// Máquina remota (destino do ssh) de onde o item veio; nil = este Mac.
    var host: String?
    /// Linha fantasma de item fixado que não está rodando.
    var isGhost = false

    /// Nome do tipo para o item: em máquina remota os "agents" são serviços systemd.
    var kindTitle: String { host != nil && kind == .agent ? "systemd" : kind.title }

    var uptime: TimeInterval? {
        guard status.isUp || status == .unhealthy, let startedAt else { return nil }
        return max(0, Date().timeIntervalSince(startedAt))
    }
}

// MARK: - Formatação

enum Fmt {
    static func uptime(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 24 { return String(format: "%d h %02d min", h, m % 60) }
        let d = h / 24
        return "\(d) d \(h % 24) h"
    }

    static func memory(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: Int64(bytes))
    }

    static func cpu(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v >= 10 ? 0 : 1))) + "%"
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
