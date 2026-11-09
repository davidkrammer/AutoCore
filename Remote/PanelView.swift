import SwiftUI

/// Draws a panel the Mac described: the same numbers, settings and buttons.
struct PanelView: View {
    let panel: RemotePanel
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ForEach(panel.blocks) { block in
                BlockView(block: block)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                if let subtitle = panel.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let counter = panel.counter {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(counter.value)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(counter.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

struct BlockView: View {
    let block: RemoteBlock

    var body: some View {
        switch block.kind {
        case let .stats(stats): StatsView(stats: stats)
        case let .status(status): StatusCard(status: status)
        case let .notice(notice): NoticeLine(notice: notice)
        case let .actions(actions): ActionsView(actions: actions)
        case let .section(section): SectionCard(section: section)
        case let .goal(goal): GoalCard(goal: goal)
        case let .rows(rows): RowsCard(rows: rows)
        }
    }
}

// MARK: - Numbers

struct StatsView: View {
    let stats: [RemoteStat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 {
                    Rectangle().fill(Palette.hairline).frame(width: 1).padding(.vertical, 12)
                }
                VStack(alignment: .leading, spacing: 3) {
                    SectionTitle(text: stat.title, color: Palette.tint(stat.tint))
                    Text(stat.value)
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(stat.footnote ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 12)
        .card(padding: 0)
        .animation(.snappy, value: stats)
    }
}

// MARK: - A run

struct StatusCard: View {
    let status: RemoteStatus

    var body: some View {
        let tint = Palette.tint(status.tint)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusDot(color: tint, pulsing: true)
                Text(status.pill)
                    .font(.caption.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(tint)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let until = status.until {
                        Label(Self.clock(until.timeIntervalSince(context.date)), systemImage: "hourglass")
                    } else if let since = status.since {
                        Label(Self.clock(context.date.timeIntervalSince(since)), systemImage: "timer")
                    }
                }
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                if let symbol = status.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .symbolEffect(.pulse, options: .repeating)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = status.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if let progress = status.progress {
                ProgressView(value: progress).tint(tint)
            }
            if !status.counters.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(status.counters.enumerated()), id: \.offset) { _, counter in
                        VStack(spacing: 1) {
                            Text(counter.value)
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(counter.tint == nil ? Color.primary : Palette.tint(counter.tint))
                                .contentTransition(.numericText())
                            Text(counter.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !status.actions.isEmpty {
                ActionsView(actions: status.actions, compact: true)
            }
        }
        .card(tint: tint)
        .animation(.snappy, value: status)
    }

    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct NoticeLine: View {
    let notice: RemoteNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.symbol)
                .foregroundStyle(Palette.tint(notice.tint))
            Text(notice.text)
                .font(.subheadline)
                .foregroundStyle(notice.tint == "secondary" ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Buttons

struct ActionsView: View {
    let actions: [RemoteAction]
    var compact = false
    @EnvironmentObject private var client: RemoteClient
    @State private var confirming: RemoteAction?

    private var primary: RemoteAction? { actions.first { $0.style == .primary && $0.subtitle != nil && !compact } }
    private var others: [RemoteAction] { actions.filter { $0.id != primary?.id } }

    var body: some View {
        VStack(spacing: 10) {
            if let primary {
                Button { run(primary) } label: {
                    HStack(spacing: 12) {
                        if let symbol = primary.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 38, height: 38)
                                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(primary.title).font(.headline)
                            if let subtitle = primary.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .opacity(0.85)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(primary.tint == nil ? AnyShapeStyle(Palette.primaryGradient) : AnyShapeStyle(Palette.tint(primary.tint).gradient),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!primary.enabled)
                .opacity(primary.enabled ? 1 : 0.45)
            }
            let rest = others
            if rest.count <= 2 && rest.allSatisfy({ $0.subtitle == nil }) {
                HStack(spacing: 10) {
                    ForEach(rest) { button($0) }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(rest) { button($0) }
                }
            }
        }
        .alert(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { action in
            Button("Cancel", role: .cancel) {}
            Button(action.title, role: .destructive) { client.perform(action.id) }
        } message: { action in
            Text(action.confirm ?? "")
        }
    }

    private func run(_ action: RemoteAction) {
        guard action.enabled else { return }
        if action.confirm != nil {
            confirming = action
            return
        }
        Haptics.tap()
        client.perform(action.id)
    }

    @ViewBuilder private func button(_ action: RemoteAction) -> some View {
        let tint = action.style == .destructive ? Palette.danger
            : action.style == .primary ? Palette.tint(action.tint ?? "accent") : Palette.tint(action.tint ?? "accent")
        Button { run(action) } label: {
            HStack(spacing: 10) {
                if let symbol = action.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let subtitle = action.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if action.subtitle != nil { Spacer(minLength: 0) }
            }
            .foregroundStyle(action.style == .primary ? Color.white : tint)
            .padding(.horizontal, 14)
            .padding(.vertical, action.subtitle == nil ? 12 : 10)
            .frame(maxWidth: .infinity, alignment: action.subtitle == nil ? .center : .leading)
            .background(action.style == .primary ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!action.enabled)
        .opacity(action.enabled ? 1 : 0.4)
    }
}

// MARK: - Settings

struct SectionCard: View {
    let section: RemoteSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = section.title { SectionTitle(text: title) }
            ForEach(section.controls) { control in
                ControlView(control: control)
            }
            if let footer = section.footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!section.enabled)
        .opacity(section.enabled ? 1 : 0.55)
        .card()
    }
}

struct ControlView: View {
    let control: RemoteControl
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        switch control.kind {
        case let .toggle(title, value):
            Toggle(isOn: Binding(get: { value }, set: { client.set(control.id, .bool($0)) })) {
                Text(title).font(.subheadline)
            }
            .tint(Palette.accent)
        case let .choice(title, options, value, style):
            if style == .menu {
                HStack {
                    if let title { Text(title).font(.subheadline) }
                    Spacer()
                    Picker(title ?? "", selection: Binding(get: { value }, set: { client.set(control.id, .string($0)) })) {
                        ForEach(options) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .tint(Palette.accent)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let title { SectionTitle(text: title) }
                    ChipFlow(options: options, selected: [value]) { id in
                        guard id != value else { return }
                        Haptics.tap()
                        client.set(control.id, .string(id))
                    }
                }
            }
        case let .multi(title, options, values, minimum):
            VStack(alignment: .leading, spacing: 8) {
                if let title { SectionTitle(text: title) }
                ChipFlow(options: options, selected: Set(values), multiple: true) { id in
                    var list = values
                    if let index = list.firstIndex(of: id) {
                        guard list.count > minimum else { Haptics.warning(); return }
                        list.remove(at: index)
                    } else {
                        list.append(id)
                    }
                    Haptics.tap()
                    client.set(control.id, .strings(list))
                }
            }
        case let .number(title, value, minimum, maximum, step, format, zeroTitle):
            Stepper(value: Binding(get: { value }, set: { client.set(control.id, .int($0)) }), in: minimum...maximum, step: step) {
                HStack {
                    Text(title).font(.subheadline)
                    Spacer()
                    Text(value == 0 && zeroTitle != nil ? zeroTitle! : format.map { String(format: $0, value) } ?? "\(value)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.accent)
                }
            }
        case let .text(title, value, placeholder):
            TextSetting(key: control.id, title: title, value: value, placeholder: placeholder)
        case let .info(title, value):
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(value).font(.subheadline).foregroundStyle(.secondary)
            }
        case let .note(text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case let .button(action):
            ActionsView(actions: [action], compact: true)
        }
    }
}

/// Sends the text a moment after typing stops, and on Return.
struct TextSetting: View {
    let key: String
    let title: String
    let value: String
    let placeholder: String
    @EnvironmentObject private var client: RemoteClient
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            TextField(placeholder, text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.done)
                .padding(10)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit { client.set(key, .string(draft)) }
                .task(id: draft) {
                    guard focused, draft != value else { return }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    client.set(key, .string(draft))
                }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, new in if !focused { draft = new } }
    }
}

struct ChipFlow: View {
    let options: [RemoteOption]
    let selected: Set<String>
    var multiple = false
    let onTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(options) { option in
                let on = selected.contains(option.id)
                let tint = Palette.tint(option.tint ?? "accent")
                Button { onTap(option.id) } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(option.tint != nil ? tint : on ? Color.white : Color.secondary)
                        } else if multiple && on {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        }
                        Text(option.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
                    .background(on ? AnyShapeStyle((option.tint != nil && multiple ? tint : Palette.accent).opacity(0.85).gradient)
                                   : AnyShapeStyle(Color.white.opacity(0.07)),
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Color.clear : Palette.hairline))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

// MARK: - Goal

struct GoalCard: View {
    let goal: RemoteGoal
    @EnvironmentObject private var client: RemoteClient
    @State private var editing = false
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: goal.title)
                Spacer()
                if goal.editKey != nil {
                    Button(goal.count == nil ? "Enter count" : "Correct") {
                        entry = goal.count.map(String.init) ?? ""
                        editing = true
                    }
                    .font(.caption.weight(.semibold))
                    .tint(Palette.accent)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(goal.count.map { $0.formatted() } ?? "–")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("/ \(goal.goal.formatted())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let count = goal.count, count >= goal.goal {
                    Label("Done", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.success)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Palette.primaryGradient)
                        .frame(width: geometry.size.width * min(1, Double(goal.count ?? 0) / Double(max(1, goal.goal))))
                }
            }
            .frame(height: 6)
            Text(goal.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let estimate = goal.estimate {
                Label(estimate, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
        .alert(goal.title, isPresented: $editing) {
            TextField("Count", text: $entry).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let digits = entry.filter(\.isNumber)
                if let key = goal.editKey, let count = Int(digits) { client.set(key, .int(count)) }
            }
        } message: {
            Text("Type the number the iPhone shows.")
        }
    }
}

// MARK: - Lists

struct RowsCard: View {
    let rows: RemoteRows
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = rows.title { SectionTitle(text: title) }
            if rows.rows.isEmpty, let empty = rows.empty {
                Text(empty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                            .padding(.leading, row.symbol == nil && row.image == nil ? 0 : 40)
                    }
                    RowView(row: row)
                }
            }
            if let footer = rows.footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}

struct RowView: View {
    let row: RemoteRow
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        let content = HStack(spacing: 10) {
            if let image = row.image, let url = URL(string: image) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.none).scaledToFit()
                    } else {
                        Color.white.opacity(0.06).clipShape(Circle())
                    }
                }
                .frame(width: 30, height: 30)
            } else if let symbol = row.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.tint(row.tint))
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if let trailing = row.trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.caption.weight(row.action == nil ? .regular : .semibold))
                    .foregroundStyle(row.action == nil ? Color.secondary : Palette.tint(row.tint ?? "accent"))
                    .monospacedDigit()
            }
            if let checked = row.checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(checked ? Palette.accent : Color.secondary.opacity(0.6))
            } else if row.action != nil && row.trailing == nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .opacity(row.enabled ? 1 : 0.5)

        if let action = row.action, row.enabled {
            Button {
                Haptics.tap()
                client.perform(action)
            } label: { content }
            .buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Lays out views in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
