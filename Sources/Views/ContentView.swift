import Combine
import SwiftUI

/// One window: the mirrored iPhone on the left, the app's panel on the right.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var windows = WindowRegistry.shared
    @ObservedObject private var repair = TextRecognitionRepair.shared
    /// Each window shows its own tab: one can run a tool while the other runs another.
    @AppStorage private var selectedMode: String
    @State private var showRemote = AppData.demoScenario == "remote"
    @State private var manualStatus: String?
    /// Per window: only the mirrored iPhone, without the panel.
    @AppStorage private var panelCollapsed: Bool
    static let panelWidth: CGFloat = 420
    static let phoneHeight: CGFloat = 760

    init(window: String) {
        _selectedMode = WindowSetting.storage(AppBrand.key("selectedMode"), window: window,
                                              default: Tools.defaultMode)
        if AppData.demoScenario?.hasSuffix("collapsed") == true {
            AppData.preferences.set(true, forKey: WindowSetting.key(AppBrand.key("panelCollapsed"), window: window))
        }
        _panelCollapsed = WindowSetting.storage(AppBrand.key("panelCollapsed"), window: window, default: false)
    }

    var body: some View {
        let aspect = PhonePaneLayout.aspectRatio(videoSize: model.receiver.videoSize,
                                                 hasFrame: model.receiver.hasFrame)
        let maximumPhoneWidth = Self.phoneHeight * PhonePaneLayout.iPhoneXSMaxAspectRatio
        let phoneSize = PhonePaneLayout.size(availableWidth: maximumPhoneWidth + Self.panelWidth + 1,
                                             availableHeight: Self.phoneHeight,
                                             dashboardWidth: Self.panelWidth,
                                             aspectRatio: aspect)
        HStack(spacing: 0) {
            MirrorPane(receiver: model.receiver,
                       onTap: { point in sendManualGesture { try await model.tap(point, exact: true) } },
                       onDrag: { start, end in
                           sendManualGesture { try await model.drag(from: start, to: end, duration: 0.45, exact: true) }
                       })
                .frame(width: phoneSize.width, height: phoneSize.height)
                .frame(width: maximumPhoneWidth, height: Self.phoneHeight)
                .background(.black)
                .help(manualStatus ?? NSLocalizedString("Click or drag the AirPlay view to control the iPhone. After a click, your Mac keyboard types on the iPhone too.", comment: "Mirror help"))
                .overlay(alignment: .top) {
                    if panelCollapsed {
                        model.tools.runBar(showPanel: { panelCollapsed = false })
                            .padding(.top, 6)
                    }
                }
            if !panelCollapsed {
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(width: 1)
                VStack(alignment: .leading, spacing: 14) {
                    model.tools.panel(selection: $selectedMode)
                }
                .padding(16)
                .frame(width: Self.panelWidth, height: Self.phoneHeight, alignment: .top)
                .background(Palette.canvas)
            }
        }
        .frame(width: maximumPhoneWidth + (panelCollapsed ? 0 : Self.panelWidth + 1), height: Self.phoneHeight)
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .toolbarBackground(Palette.canvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AccountButton(model: model, receiver: model.receiver, connector: model.phoneConnector,
                              actions: menuActions, compact: panelCollapsed)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    panelCollapsed.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .symbolVariant(panelCollapsed ? .none : .fill)
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .help(panelCollapsed
                      ? NSLocalizedString("Show the panel (⌃⌘S)", comment: "Sidebar toggle")
                      : NSLocalizedString("Hide the panel: only the iPhone (⌃⌘S)", comment: "Sidebar toggle"))
                .accessibilityLabel(Text(panelCollapsed ? "Show the panel" : "Hide the panel"))
            }
        }
        .sheet(isPresented: $showRemote) { RemoteSettingsView().preferredColorScheme(.dark) }
        .modifier(RemotePairingAlert(isFirstWindow: windows.models.first.map { $0 === model } ?? true))
        .modifier(model.tools.windowExtras())
        .background(WindowReader { window in
            model.hostWindow = window
            placeBesideOtherWindow(window)
        })
        .task { await reopenOtherWindow() }
        .onAppear {
            RemoteWindowOpener.shared.opener = { [openWindow] in openWindow(id: AppScene.windowID) }
            RemoteServer.shared.startIfEnabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.prepareForQuit()
            model.stopManagedWDARunner()
        }
    }

    /// What the title bar's account menu opens in this window.
    private var menuActions: AccountMenuActions {
        AccountMenuActions(
            openSecondWindow: windows.windowCount >= 2 ? nil : { openWindow(id: AppScene.windowID) },
            showRemote: { showRemote = true },
            rebuildRecognition: repair.isRebuilding || model.isBusy ? nil : {
                // The first tab shows how the rebuild goes.
                selectedMode = Tools.defaultMode
                repair.rebuild()
            })
    }

    /// A second window opens beside the first instead of on top of it: on
    /// the same screen if there is room, else on another screen.
    private func placeBesideOtherWindow(_ window: NSWindow) {
        guard let other = windows.peer(for: model)?.hostWindow, other !== window,
              let screen = other.screen ?? window.screen else { return }
        let overlap = window.frame.intersection(other.frame)
        guard overlap.width * overlap.height > 0.3 * window.frame.width * window.frame.height else { return }
        let size = window.frame.size
        let area = screen.visibleFrame
        let top = min(other.frame.maxY, area.maxY)
        for x in [other.frame.maxX + 12, other.frame.minX - 12 - size.width]
        where x >= area.minX && x + size.width <= area.maxX {
            window.setFrame(NSRect(x: x, y: max(area.minY, top - size.height), width: size.width, height: size.height),
                            display: true, animate: true)
            return
        }
        if let elsewhere = NSScreen.screens.first(where: { $0 != screen
            && $0.visibleFrame.width >= size.width && $0.visibleFrame.height >= size.height })?.visibleFrame {
            window.setFrame(NSRect(x: elsewhere.midX - size.width / 2, y: elsewhere.midY - size.height / 2,
                                   width: size.width, height: size.height), display: true, animate: true)
            return
        }
        let x = other.frame.midX < area.midX ? area.maxX - size.width : area.minX
        window.setFrame(NSRect(x: x, y: max(area.minY, top - size.height), width: size.width, height: size.height),
                        display: true, animate: true)
    }

    @MainActor private static var mayReopenOtherWindow = true

    /// After an update or a restart, open the second window again when its
    /// iPhone was mirroring until the app ended; it then reconnects by itself.
    private func reopenOtherWindow() async {
        guard Self.mayReopenOtherWindow, !AppData.isDemoProcess else { return }
        Self.mayReopenOtherWindow = false
        // macOS may bring both windows back by itself; give it a moment.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard windows.windowCount == 1, !model.otherRecentlyMirroredReceivers.isEmpty else { return }
        openWindow(id: AppScene.windowID)
    }

    private func sendManualGesture(_ action: @escaping () async throws -> Void) {
        guard !model.isBusy else {
            manualStatus = NSLocalizedString("Stop automation before manual control", comment: "Manual touch status")
            return
        }
        Task {
            do {
                try await action()
                manualStatus = NSLocalizedString("Gesture sent", comment: "Manual touch status")
            } catch {
                manualStatus = error.localizedDescription
            }
        }
    }
}

/// With the panel hidden: what runs, with Stop, over the top of the mirror.
/// Apps show it from `WindowTools.runBar` while something runs.
struct RunBarCapsule: View {
    let line: String
    let tint: Color
    let showPanel: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: showPanel) {
                HStack(spacing: 7) {
                    StatusDot(color: tint, pulsing: true)
                    Text(line)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Show the panel", comment: "Collapsed run bar"))
            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.danger.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 10)
    }
}

/// The app's tabs as capsules; a running tool locks the others. Tabs that
/// do not fit with their titles show only their symbol.
struct ToolModeBar: View {
    @Binding var selection: String
    let modes: [ToolMode]
    let locked: Bool

    private var options: [CapsulePicker<String>.Option] {
        modes.map { .init(value: $0.id, title: LocalizedStringKey($0.title), symbol: $0.symbol, tint: $0.tint) }
    }

    var body: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                CapsulePicker(selection: $selection, options: options, disabled: { _ in locked })
                CapsulePicker(selection: $selection, options: options, disabled: { _ in locked }, compact: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Hands over the window a view is in, once it is in one.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // After SwiftUI has sized the window.
            DispatchQueue.main.async { [onWindow] in onWindow(window) }
        }
    }
}

enum PhonePaneLayout {
    static let iPhone17ProMaxAspectRatio: CGFloat = 1320.0 / 2868.0
    static let iPhoneXSMaxAspectRatio: CGFloat = 1242.0 / 2688.0

    static func aspectRatio(videoSize: CGSize, hasFrame: Bool) -> CGFloat {
        guard hasFrame, videoSize.width > 0, videoSize.height > 0 else {
            return iPhone17ProMaxAspectRatio
        }
        let ratio = videoSize.width / videoSize.height
        return (0.4...0.6).contains(ratio) ? ratio : iPhone17ProMaxAspectRatio
    }

    static func size(
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        dashboardWidth: CGFloat,
        aspectRatio: CGFloat
    ) -> CGSize {
        guard aspectRatio > 0 else { return .zero }
        let width = min(
            max(0, availableWidth - dashboardWidth - 1),
            max(0, availableHeight) * aspectRatio
        )
        return CGSize(width: width, height: width / aspectRatio)
    }
}

