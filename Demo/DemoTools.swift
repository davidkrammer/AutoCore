import Combine
import SwiftUI

/// The demo's tools: a few things to try on the mirrored iPhone, each with a
/// Mac panel and a Remote page. A real app keeps this shape and puts its own
/// automations behind the buttons.
@MainActor
final class Tools: ObservableObject, WindowTools {
    unowned let model: AppModel
    /// The step that runs, e.g. "Opening App Store…".
    @Published private(set) var running: String?
    /// What the last step did, or why it failed.
    @Published private(set) var status: String?
    /// The lines the Read tab found on the screen, top to bottom.
    @Published private(set) var lines: [ScreenText] = []
    private var runningMode: String?
    private var task: Task<Void, Never>?
    private var forward: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        // The window redraws its touch and typing state with the run.
        forward = $running.removeDuplicates().sink { [weak model] _ in model?.objectWillChange.send() }
    }

    // MARK: - What the buttons do

    struct Shortcut: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let bundleIdentifier: String
    }

    /// Apple's apps are on every iPhone.
    static let shortcuts = [
        Shortcut(id: "appStore", title: "App Store", symbol: "bag.fill", bundleIdentifier: "com.apple.AppStore"),
        Shortcut(id: "settings", title: "Settings", symbol: "gearshape.fill", bundleIdentifier: "com.apple.Preferences"),
        Shortcut(id: "safari", title: "Safari", symbol: "safari.fill", bundleIdentifier: "com.apple.mobilesafari"),
        Shortcut(id: "photos", title: "Photos", symbol: "photo.on.rectangle", bundleIdentifier: "com.apple.mobileslideshow"),
    ]

    func open(_ shortcut: Shortcut) {
        run(String(format: NSLocalizedString("Opening %@…", comment: "Demo"), shortcut.title), mode: "basics") { [model] in
            try await model.openApp(shortcut.bundleIdentifier)
            return String(format: NSLocalizedString("%@ is open", comment: "Demo"), shortcut.title)
        }
    }

    func goHome() {
        run(NSLocalizedString("Going to the Home Screen…", comment: "Demo"), mode: "basics") { [model] in
            try await model.goHome()
            return NSLocalizedString("Home Screen", comment: "Demo")
        }
    }

    /// Up: the content moves up, like reading further down a page.
    func scroll(up: Bool) {
        run(NSLocalizedString("Swiping…", comment: "Demo"), mode: "basics") { [model] in
            let low = NormalizedPoint(x: 0.5, y: 0.72), high = NormalizedPoint(x: 0.5, y: 0.32)
            try await model.drag(from: up ? low : high, to: up ? high : low, duration: 0.35)
            return NSLocalizedString("Swiped", comment: "Demo")
        }
    }

    /// Types into whatever text field is active on the iPhone.
    func type(_ text: String) {
        let text = text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        run(NSLocalizedString("Typing…", comment: "Demo"), mode: "basics") { [model] in
            try await model.typeText(text)
            return String(format: NSLocalizedString("Typed “%@”", comment: "Demo"), text)
        }
    }

    func readScreen() {
        run(NSLocalizedString("Reading the screen…", comment: "Demo"), mode: "read") { [weak self, model] in
            let found = try await model.readScreen()
            self?.lines = found
            return String(format: NSLocalizedString("%d lines of text", comment: "Demo"), found.count)
        }
    }

    /// Reads the screen, then taps the first line that contains `text`.
    func findAndTap(_ text: String) {
        let wanted = ScreenText(value: text, rect: .zero, confidence: 1).normalized
        guard !wanted.isEmpty else { return }
        run(String(format: NSLocalizedString("Looking for “%@”…", comment: "Demo"), text), mode: "read") { [weak self, model] in
            let found = try await model.readScreen()
            self?.lines = found
            guard let match = found.first(where: { $0.normalized.contains(wanted) }) else {
                return String(format: NSLocalizedString("“%@” is not on the screen", comment: "Demo"), text)
            }
            try await model.tap(match.point)
            return String(format: NSLocalizedString("Tapped “%@”", comment: "Demo"), match.value)
        }
    }

    private func run(_ title: String, mode: String, _ body: @escaping () async throws -> String) {
        guard running == nil else { return }
        running = title
        runningMode = mode
        status = nil
        task = Task { [weak self] in
            let result: String
            do {
                result = try await body()
            } catch is CancellationError {
                result = NSLocalizedString("Stopped", comment: "Demo")
            } catch {
                result = error.localizedDescription
            }
            guard let self else { return }
            self.status = result
            self.running = nil
            self.runningMode = nil
            self.task = nil
        }
    }

    // MARK: - WindowTools: tabs and panels

    static let defaultMode = "basics"

    var modes: [ToolMode] {
        [ToolMode(id: "basics", title: "Basics", symbol: "hand.tap.fill", tint: Palette.accent, remoteTint: "accent"),
         ToolMode(id: "read", title: "Read", symbol: "text.viewfinder", tint: Palette.indigo, remoteTint: "indigo")]
    }

    var lockedMode: String? { running == nil ? nil : runningMode }

    func panel(selection: Binding<String>) -> some View {
        DemoPanel(tools: self, selection: selection)
    }

    func runBar(showPanel: @escaping () -> Void) -> some View {
        DemoRunBar(tools: self, showPanel: showPanel)
    }

    func mirrorOverlay() -> some View {
        DemoMirrorOverlay(tools: self)
    }

    func windowExtras() -> some ViewModifier { NoWindowExtras() }

    static func commands(for model: AppModel?) -> some View {
        Group {
            Button("Open App Store") { model?.tools.open(Tools.shortcuts[0]) }
                .keyboardShortcut("1", modifiers: [.command])
            Button("Go to the Home Screen") { model?.tools.goHome() }
                .keyboardShortcut("2", modifiers: [.command])
            Button("Read the Screen") { model?.tools.readScreen() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("Stop") { model?.tools.stopActiveRun() }
                .keyboardShortcut(".", modifiers: [.command])
        }
        .disabled(model == nil)
    }

    // MARK: - WindowTools: state

    var isBusy: Bool { running != nil }
    var activityLine: String? { running }

    var changes: AnyPublisher<Void, Never> {
        $running.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
    }

    func stopActiveRun() { task?.cancel() }

    // MARK: - WindowTools: account

    func accountBadge(_ name: String, size: CGFloat) -> some View { AccountBadge(name: name, size: size) }
    func accountSection(close: @escaping () -> Void) -> some View { EmptyView() }
    func menuItems(close: @escaping () -> Void) -> some View { EmptyView() }
    /// The demo does not know accounts.
    func activateAccount(_ name: String) -> Bool { false }

    // MARK: - WindowTools: mirroring

    func mirrorStarted() {}
    func mirrorStopped() { stopActiveRun() }
    func mirrorWillDisconnect() { stopActiveRun() }
    func windowWillClose() { stopActiveRun() }
    var waitsForMirror: Bool { false }
    var allowsSessionCreation: Bool { true }

    func applyDemoScenario(_ scenario: String) {
        // What the Read tab finds on iOS Settings › General, for screenshots.
        let sample: [(String, Double)] = [("General", 0.29), ("About", 0.496), ("Screen Capture", 0.596),
                                          ("AutoFill & Passwords", 0.695), ("Dictionary", 0.755), ("Fonts", 0.814),
                                          ("Keyboard", 0.874), ("Language & Region", 0.934)]
        let demoLines = sample.map { text, y in
            ScreenText(value: text, rect: CGRect(x: 0.18, y: y - 0.012, width: 0.5, height: 0.024), confidence: 1)
        }
        switch scenario {
        case "running":
            running = String(format: NSLocalizedString("Looking for “%@”…", comment: "Demo"), "Keyboard")
            runningMode = "read"
            lines = demoLines
            model.lastGesture = TouchFeedback(start: NormalizedPoint(x: 0.3, y: 0.874), end: nil)
        case "read":
            AppData.preferences.set("read", forKey: model.selectedModeKey)
            lines = demoLines
            status = String(format: NSLocalizedString("%d lines of text", comment: "Demo"), demoLines.count)
        default:
            break
        }
    }

    // MARK: - WindowTools: Remote

    func remotePanel(for mode: String, builder: RemotePanelBuilder) -> RemotePanel {
        var blocks: [RemoteBlock] = []
        if let running {
            blocks.append(RemoteBlock("status", .status(RemoteStatus(
                pill: NSLocalizedString("RUNNING", comment: "Remote pill"), tint: "accent", title: running,
                symbol: "hand.tap.fill",
                actions: [builder.stopAction("stop") { [weak self] in self?.stopActiveRun() }]))))
        } else if let status {
            blocks.append(RemoteBlock("result", .notice(RemoteNotice(text: status, symbol: "checkmark.circle", tint: "secondary"))))
        }
        let idle = running == nil
        if mode == "read" {
            blocks.append(RemoteBlock("read", .actions([
                builder.action("read.screen", NSLocalizedString("Read the screen", comment: "Demo"), symbol: "text.viewfinder",
                               style: .primary, enabled: idle) { [weak self] in self?.readScreen() },
            ])))
            blocks.append(RemoteBlock("find", .section(RemoteSection(
                title: NSLocalizedString("Find and tap", comment: "Demo"),
                footer: NSLocalizedString("Reads the screen, then taps the first line with this text.", comment: "Demo"),
                controls: [builder.localText("read.find", NSLocalizedString("Text", comment: "Demo"),
                                             placeholder: NSLocalizedString("e.g. Wi-Fi", comment: "Demo"))]))))
            let wanted = builder.local["read.find"] ?? ""
            blocks.append(RemoteBlock("findAction", .actions([
                builder.action("read.tap", NSLocalizedString("Find and tap", comment: "Demo"), symbol: "hand.point.up.left.fill",
                               enabled: idle && !wanted.isEmpty) { [weak self] in self?.findAndTap(wanted) },
            ])))
            blocks.append(RemoteBlock("lines", .rows(RemoteRows(
                title: NSLocalizedString("On the screen", comment: "Demo"),
                rows: lines.prefix(40).enumerated().map { index, line in
                    RemoteRow(id: "\(index)", title: line.value, detail: String(format: "%.0f%%", line.confidence * 100))
                },
                empty: NSLocalizedString("Read the screen to see its text here.", comment: "Demo")))))
        } else {
            blocks.append(RemoteBlock("apps", .actions(Self.shortcuts.map { shortcut in
                builder.action("open." + shortcut.id, shortcut.title, symbol: shortcut.symbol, enabled: idle) { [weak self] in
                    self?.open(shortcut)
                }
            })))
            blocks.append(RemoteBlock("moves", .actions([
                builder.action("home", NSLocalizedString("Home Screen", comment: "Demo"), symbol: "house.fill", enabled: idle) {
                    [weak self] in self?.goHome()
                },
                builder.action("swipeUp", NSLocalizedString("Swipe up", comment: "Demo"), symbol: "arrow.up", enabled: idle) {
                    [weak self] in self?.scroll(up: true)
                },
                builder.action("swipeDown", NSLocalizedString("Swipe down", comment: "Demo"), symbol: "arrow.down", enabled: idle) {
                    [weak self] in self?.scroll(up: false)
                },
            ])))
            blocks.append(RemoteBlock("type", .section(RemoteSection(
                title: NSLocalizedString("Type on the iPhone", comment: "Demo"),
                footer: NSLocalizedString("Goes into the text field that is active on the iPhone.", comment: "Demo"),
                controls: [builder.localText("basics.text", NSLocalizedString("Text", comment: "Demo"),
                                             placeholder: NSLocalizedString("Hello from the Remote", comment: "Demo"))]))))
            let text = builder.local["basics.text"] ?? ""
            blocks.append(RemoteBlock("typeAction", .actions([
                builder.action("basics.type", NSLocalizedString("Type", comment: "Demo"), symbol: "keyboard",
                               enabled: idle && !text.isEmpty) { [weak self] in self?.type(text) },
            ])))
        }
        let title = modes.first { $0.id == mode }?.title ?? mode
        return RemotePanel(title: NSLocalizedString(title, comment: "Tab"), subtitle: model.linkSummary,
                           counter: nil, blocks: blocks)
    }

    func remoteSetup(builder: RemotePanelBuilder) -> [RemoteBlock] { [] }
}

private struct NoWindowExtras: ViewModifier {
    func body(content: Content) -> some View { content }
}

// MARK: - Mac panel

private struct DemoPanel: View {
    @ObservedObject var tools: Tools
    @Binding var selection: String
    @AppStorage private var typed: String
    @AppStorage private var find: String

    init(tools: Tools, selection: Binding<String>) {
        self.tools = tools
        _selection = selection
        let window = tools.model.receiver.receiverName
        _typed = WindowSetting.storage(AppBrand.key("demoText"), window: window, default: "")
        _find = WindowSetting.storage(AppBrand.key("demoFind"), window: window, default: "")
    }

    private var mode: String { tools.lockedMode ?? selection }
    private var idle: Bool { tools.running == nil && tools.model.controlPhase == .ready }

    var body: some View {
        // A running tool keeps its tab shown and the others locked.
        ToolModeBar(selection: Binding(get: { mode }, set: { selection = $0 }), modes: tools.modes,
                    locked: tools.lockedMode != nil)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusCard
                if mode == "read" { readTab } else { basicsTab }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder private var statusCard: some View {
        if let running = tools.running {
            HStack(spacing: 10) {
                StatusDot(color: Palette.accent, pulsing: true)
                Text(running).font(.callout.weight(.semibold))
                Spacer()
                Button("Stop", role: .destructive) { tools.stopActiveRun() }
                    .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else if let status = tools.status {
            Label(status, systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        } else if tools.model.controlPhase != .ready {
            Label("Connect an iPhone on the left to try these.", systemImage: "iphone")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }

    private var basicsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Open an app")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Tools.shortcuts) { shortcut in
                        Button { tools.open(shortcut) } label: {
                            Label(shortcut.title, systemImage: shortcut.symbol).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Move around")
                HStack(spacing: 8) {
                    Button { tools.goHome() } label: { Label("Home", systemImage: "house.fill").frame(maxWidth: .infinity) }
                    Button { tools.scroll(up: true) } label: { Label("Swipe up", systemImage: "arrow.up").frame(maxWidth: .infinity) }
                    Button { tools.scroll(up: false) } label: { Label("Swipe down", systemImage: "arrow.down").frame(maxWidth: .infinity) }
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Type on the iPhone")
                HStack(spacing: 8) {
                    TextField("Hello from the Mac", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { tools.type(typed) }
                    Button("Type") { tools.type(typed) }
                        .disabled(typed.isEmpty)
                }
                Text("Goes into the text field that is active on the iPhone. Clicking the mirror and typing on the Mac works too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .disabled(!idle)
    }

    private var readTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Text recognition")
                Button { tools.readScreen() } label: {
                    Label("Read the screen", systemImage: "text.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                HStack(spacing: 8) {
                    TextField("Find and tap, e.g. Wi-Fi", text: $find)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { tools.findAndTap(find) }
                    Button("Tap") { tools.findAndTap(find) }
                        .disabled(find.isEmpty)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .disabled(!idle)
            if !tools.lines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(title: "On the screen")
                    ForEach(Array(tools.lines.prefix(40).enumerated()), id: \.offset) { _, line in
                        HStack {
                            Text(line.value).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", line.confidence * 100))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
        }
    }
}

private struct DemoRunBar: View {
    @ObservedObject var tools: Tools
    let showPanel: () -> Void

    var body: some View {
        if let running = tools.running {
            RunBarCapsule(line: running, tint: Palette.accent, showPanel: showPanel, stop: tools.stopActiveRun)
        }
    }
}

private struct DemoMirrorOverlay: View {
    @ObservedObject var tools: Tools

    var body: some View {
        if let running = tools.running {
            MirrorChip(text: LocalizedStringKey(running), value: running)
        }
    }
}
