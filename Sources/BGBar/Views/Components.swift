import SwiftUI

// MARK: - Constantes visuais

enum UI {
    static let width: CGFloat = 400
    static let maxHeight: CGFloat = 560
    /// Altura fixa da área acima do rodapé (cabeçalho + abas + conteúdo, ou o detalhe).
    static let bodyHeight: CGFloat = 470
    static let pad: CGFloat = 12
    static let radius: CGFloat = 10
    // Mantidas só por compatibilidade com views de outros arquivos; a UI não anima mais.
    static let spring = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.15)
}

// MARK: - Bolinha de status

struct StatusDot: View {
    let status: Status
    var size: CGFloat = 8

    var body: some View {
        // Estados transitórios ganham um anel estático (sem pulso).
        ZStack {
            Circle()
                .strokeBorder(status.color.opacity(status.isTransient ? 0.45 : 0), lineWidth: 1.5)
                .padding(-2.5)
            Circle()
                .fill(status.color)
                .shadow(color: glow ? status.color.opacity(0.7) : .clear, radius: 3)
            Circle()
                .strokeBorder(.white.opacity(glow ? 0.25 : 0), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
    }

    private var glow: Bool { status != .stopped && status != .notLoaded }
}

// MARK: - Chip

struct Chip: View {
    var text: String
    var symbol: String? = nil
    var tint: Color? = nil
    var mono = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            }
            Text(text)
                .font(mono ? .system(size: 10, design: .monospaced) : .system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous).fill((tint ?? .primary).opacity(tint == nil ? 0.06 : 0.13))
        )
    }
}

struct PortChip: View {
    let port: Int
    var host: String? = nil
    @State private var hover = false

    var body: some View {
        Button { Actions.openPort(port, host: host) } label: {
            HStack(spacing: 2) {
                Text(":\(String(port))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                // Sempre no layout; só fica visível no hover (largura não muda).
                Image(systemName: "arrow.up.right").font(.system(size: 7.5, weight: .bold))
                    .opacity(hover ? 1 : 0)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(Color.accentColor.opacity(hover ? 0.22 : 0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Abrir http://\(Actions.portHost(host)):\(String(port))")
    }
}

// MARK: - Botões

/// Botão de ícone redondo usado em linhas, cabeçalho e detalhe.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color = .secondary
    var size: CGFloat = 22
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(hover ? Color.primary : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Botão "pílula" da barra de ações do detalhe.
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(prominent ? Color.white : tint)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? tint.opacity(hover ? 1 : 0.88) : tint.opacity(hover ? 0.16 : 0.09))
                )
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .onHover { hover = $0 }
        }
    }
}

// MARK: - Cartão

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: UI.radius, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UI.radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}

// MARK: - Medição de altura (para o popover crescer até o máximo e então rolar)

struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func measureHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            .onPreferenceChange(HeightKey.self, perform: onChange)
    }
}

// MARK: - Helpers de Item

extension Item {
    /// Nota de status útil para chip (evita repetir o label).
    var chipStatusText: String {
        if let note = statusNote, !note.isEmpty, note.lowercased() != status.label { return "\(status.label) · \(note)" }
        if status == .failed, let exitCode { return "\(status.label) · código \(exitCode)" }
        return status.label
    }
}
