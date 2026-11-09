import SwiftUI

/// The Mac app's dark look.
enum Palette {
    static let canvas = Color(red: 0.055, green: 0.059, blue: 0.071)
    static let surface = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.08)
    static let accent = Color(red: 0.20, green: 0.78, blue: 0.76)
    static let accentDeep = Color(red: 0.14, green: 0.56, blue: 0.86)
    static let indigo = Color(red: 0.49, green: 0.56, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.43, blue: 0.66)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.27)
    static let success = Color(red: 0.32, green: 0.82, blue: 0.52)
    static let warning = Color(red: 1.00, green: 0.73, blue: 0.27)
    static let danger = Color(red: 1.00, green: 0.40, blue: 0.40)

    static let primaryGradient = LinearGradient(colors: [Color(red: 0.16, green: 0.72, blue: 0.70),
                                                         Color(red: 0.13, green: 0.58, blue: 0.74)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The Mac names its colours; anything else is "#RRGGBB".
    static func tint(_ name: String?) -> Color {
        switch name {
        case "accent": return accent
        case "indigo": return indigo
        case "pink": return pink
        case "orange": return orange
        case "success": return success
        case "warning": return warning
        case "danger": return danger
        case "secondary", nil: return .secondary
        case let hex?:
            guard hex.hasPrefix("#"), hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return accent }
            return Color(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255,
                         blue: Double(value & 255) / 255)
        }
    }

    static func link(_ state: String?) -> Color {
        switch state {
        case "ready": return success
        case "working": return warning
        case "problem": return danger
        default: return .secondary
        }
    }
}

struct Card: ViewModifier {
    var tint: Color?
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint ?? .white).opacity(tint == nil ? 0.055 : 0.10),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder((tint ?? .white).opacity(tint == nil ? 0.08 : 0.25)))
    }
}

extension View {
    func card(tint: Color? = nil, padding: CGFloat = 14) -> some View {
        modifier(Card(tint: tint, padding: padding))
    }

    /// The soft iOS 26 scroll edge under the bars.
    func softEdges() -> some View {
        scrollEdgeEffectStyle(.soft, for: .all)
    }
}

struct SectionTitle: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(pulsing && dim ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = true }
    }
}

/// An account's round initial, coloured from the name like on the Mac.
struct AccountBadge: View {
    let name: String?
    var size: CGFloat = 28

    private var color: Color {
        guard let name else { return .gray }
        let hues: [Double] = [0.47, 0.55, 0.62, 0.08, 0.95, 0.33, 0.75, 0.13]
        let sum = name.lowercased().unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color(hue: hues[sum % hues.count], saturation: 0.50, brightness: 0.78)
    }

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            if let name, let first = name.first {
                Text(String(first).uppercased())
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "iphone")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: size, height: size)
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
