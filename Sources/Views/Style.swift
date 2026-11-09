import SwiftUI

/// One small design system for every surface: a near-black canvas, quiet
/// surfaces with hairline edges, one teal accent and a fixed colour per
/// activity. The app always uses its dark appearance.
enum Palette {
    static let canvas = Color(red: 0.055, green: 0.059, blue: 0.071)
    static let surface = Color.white.opacity(0.045)
    static let surfaceRaised = Color.white.opacity(0.075)
    static let hairline = Color.white.opacity(0.075)

    static let accent = Color(red: 0.20, green: 0.78, blue: 0.76)
    static let accentDeep = Color(red: 0.14, green: 0.56, blue: 0.86)
    static let indigo = Color(red: 0.49, green: 0.56, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.43, blue: 0.66)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.27)
    static let success = Color(red: 0.32, green: 0.82, blue: 0.52)
    static let warning = Color(red: 1.00, green: 0.73, blue: 0.27)
    static let danger = Color(red: 1.00, green: 0.40, blue: 0.40)

    static var primaryGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.16, green: 0.72, blue: 0.70), Color(red: 0.13, green: 0.58, blue: 0.74)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var orangeGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.98, green: 0.58, blue: 0.22), Color(red: 0.93, green: 0.40, blue: 0.22)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Stable, pleasant avatar colour per name.
    static func avatar(for name: String) -> Color {
        let hues: [Double] = [0.52, 0.58, 0.64, 0.72, 0.80, 0.88, 0.96, 0.04, 0.10, 0.30, 0.42]
        let sum = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: hues[sum % hues.count], saturation: 0.50, brightness: 0.78)
    }
}

/// A quiet surface with a hairline edge. A tint is reserved for states that
/// need attention, such as a warning or a finished run.
struct CardBackground: ViewModifier {
    var tint: Color?
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Palette.surface)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.07))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint?.opacity(0.20) ?? Palette.hairline, lineWidth: 1)
            }
    }
}

extension View {
    func card(tint: Color? = nil, cornerRadius: CGFloat = 16) -> some View {
        modifier(CardBackground(tint: tint, cornerRadius: cornerRadius))
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    var gradient: LinearGradient = Palette.primaryGradient

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, gradient: gradient)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let gradient: LinearGradient
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .actionButtonShape()
                .foregroundStyle(isEnabled ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity)
                .background {
                    if isEnabled {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(gradient)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06))
                    }
                }
                .overlay {
                    // A soft top highlight gives the button its depth.
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isEnabled
                                      ? LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.04)],
                                                       startPoint: .top, endPoint: .bottom)
                                      : LinearGradient(colors: [Palette.hairline], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 1)
                }
                .brightness(configuration.isPressed ? -0.06 : hovering && isEnabled ? 0.04 : 0)
                .scaleEffect(configuration.isPressed ? 0.988 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// A neutral button: the icon carries the colour, the title stays white.
/// Destructive or cautionary buttons colour their title too.
struct SecondaryActionButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var tintedTitle = false

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, tint: tint, tintedTitle: tintedTitle)
    }

    private struct SecondaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let tintedTitle: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(TintedIconLabelStyle(tint: isEnabled ? tint : .secondary))
                .actionButtonShape()
                .foregroundStyle(isEnabled ? (tintedTitle ? tint : Color.primary) : Color.secondary)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.09 : 0.06))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                }
                .opacity(isEnabled ? 1 : 0.55)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// Every action button gets room around its title, also a plain
    /// `Button("Save")` without padding of its own; a label that sets its
    /// own font or padding keeps them.
    func actionButtonShape() -> some View {
        font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
    }
}

struct TintedIconLabelStyle: LabelStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

/// A capsule segmented control in the app style.
struct CapsulePicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: LocalizedStringKey
        var symbol: String?
        var tint: Color = Palette.accent
        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]
    var disabled: (Value) -> Bool = { _ in false }
    /// Unselected options with a symbol show only the symbol, so a long row
    /// such as the mode bar fits; the title stays in the tooltip.
    var compact = false
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = option.value }
                } label: {
                    HStack(spacing: 6) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(selected ? option.tint : Color.secondary)
                        }
                        if !compact || selected || option.symbol == nil {
                            Text(option.title)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.white.opacity(0.11))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(disabled(option.value) && !selected)
                .help(compact && !selected ? Text(option.title) : Text(verbatim: ""))
                .accessibilityLabel(Text(option.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// Small caps label above a group, e.g. "SENT".
struct SectionLabel: View {
    let title: LocalizedStringKey
    var color: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let color {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
    }
}

/// An account's round picture: the app's image for it, else its initials.
struct AccountBadge: View {
    let name: String
    var size: CGFloat = 30
    var image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .accessibilityHidden(true)
        } else {
            initialsAvatar
        }
    }

    private var initialsAvatar: some View {
        let initials = String(name.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
        let color = Palette.avatar(for: name)
        return ZStack {
            Circle().fill(color.opacity(0.22))
            Circle().strokeBorder(color.opacity(0.35), lineWidth: 1)
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .brightness(0.15)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if pulsing {
                    Circle()
                        .stroke(color.opacity(0.6), lineWidth: 2)
                        .scaleEffect(pulse ? 2.4 : 1)
                        .opacity(pulse ? 0 : 0.9)
                }
            }
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// A row in a readiness checklist.
struct ChecklistRow: View {
    let title: String
    let done: Bool
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
                } else {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title))
                    .font(.callout)
                    .foregroundStyle(done ? .primary : .secondary)
                if let detail, !done {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

enum AppFormat {
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 {
            return NSLocalizedString("just now", comment: "Relative time")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}

/// Lays its views out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, added > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Toggle chips that wrap into rows: any number can be on, never none.
struct ChipChooser<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: LocalizedStringKey
        var tint: Color = Palette.accent
        var id: Value { value }
    }

    @Binding var selection: Set<Value>
    let options: [Option]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options) { option in
                let on = selection.contains(option.value)
                Button {
                    var next = selection
                    if on { next.remove(option.value) } else { next.insert(option.value) }
                    if !next.isEmpty { withAnimation(.snappy(duration: 0.18)) { selection = next } }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(on ? option.tint : Color.secondary)
                        Text(option.title)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(on ? Color.white.opacity(0.11) : Palette.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? option.tint.opacity(0.45) : Palette.hairline, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(on && selection.count == 1
                      ? NSLocalizedString("At least one stays chosen", comment: "Chip help") : "")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
