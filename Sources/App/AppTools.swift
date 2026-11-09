import Combine
import SwiftUI

/// One tab on the right of a window.
struct ToolMode: Identifiable, Equatable {
    /// Saved per window; the Remote sends it back to switch tabs.
    let id: String
    /// Shown on the tab, looked up in Localizable.strings.
    let title: String
    let symbol: String
    let tint: Color
    /// The tint's name for the Remote: "accent", "orange", "green", "red",
    /// "indigo" or "pink".
    let remoteTint: String
}

/// What an app built on AutoCore adds to every window: its tabs and their
/// panels, its automations and their Remote pages, and how it knows the
/// account signed in on the iPhone.
///
/// The app defines `final class Tools: WindowTools` (see
/// `Demo/DemoTools.swift`); AutoCore makes one per window and calls it.
/// Everything else (mirroring, touch control, text recognition, windows,
/// the title-bar menu and the Remote) comes from AutoCore.
@MainActor
protocol WindowTools: AnyObject {
    associatedtype Panel: View
    associatedtype RunBar: View
    associatedtype MirrorOverlay: View
    associatedtype AccountBadgeView: View
    associatedtype AccountSection: View
    associatedtype MenuItems: View
    associatedtype WindowExtras: ViewModifier
    associatedtype MenuCommands: View

    init(model: AppModel)

    // MARK: Tabs and panels

    /// The window's tabs, in order.
    var modes: [ToolMode] { get }
    /// The tab a new window opens on.
    static var defaultMode: String { get }
    /// While something runs, its tab: the others are locked.
    var lockedMode: String? { get }
    /// The right-hand panel: the tab bar (`ToolModeBar`) and the selected tab.
    func panel(selection: Binding<String>) -> Panel
    /// Over the mirror while the panel is hidden: what runs, with Stop
    /// (`RunBarCapsule`), or nothing.
    func runBar(showPanel: @escaping () -> Void) -> RunBar
    /// Over the mirrored picture, e.g. the screen a run recognised (`MirrorChip`).
    func mirrorOverlay() -> MirrorOverlay
    /// Sheets and alerts the app's windows need.
    func windowExtras() -> WindowExtras
    /// The Automation menu in the menu bar.
    static func commands(for model: AppModel?) -> MenuCommands

    // MARK: State

    /// Something runs: manual taps wait, the iPhone and account stay.
    var isBusy: Bool { get }
    /// What runs, in a few words ("Opening App Store…"), or nil.
    var activityLine: String? { get }
    /// Fires when `isBusy`, `activityLine` or `lockedMode` may have changed.
    var changes: AnyPublisher<Void, Never> { get }
    /// Stops whatever runs in this window.
    func stopActiveRun()

    // MARK: The account on the iPhone

    /// The account's round picture (`AccountBadge`).
    func accountBadge(_ name: String, size: CGFloat) -> AccountBadgeView
    /// The account part of the title-bar menu (e.g. a list to choose from),
    /// ending with a `Divider` when it shows anything.
    func accountSection(close: @escaping () -> Void) -> AccountSection
    /// The app's rows in the title-bar menu (`AccountMenuItem`).
    func menuItems(close: @escaping () -> Void) -> MenuItems
    /// Makes `name` the window's account (`model.accountName`); false if
    /// the app does not know it.
    func activateAccount(_ name: String) -> Bool

    // MARK: Mirroring and touch

    /// The iPhone's picture arrived (or came back).
    func mirrorStarted()
    /// The picture stopped.
    func mirrorStopped()
    /// The user disconnects the iPhone from the menu.
    func mirrorWillDisconnect()
    /// The window closes: stop everything.
    func windowWillClose()
    /// A run waits for the picture: mirror again by itself when it drops.
    var waitsForMirror: Bool { get }
    /// A new touch session may bring the app's iPhone app to the front.
    var allowsSessionCreation: Bool { get }
    /// Sample state for `--ui-demo <scenario>` screenshots.
    func applyDemoScenario(_ scenario: String)

    // MARK: Remote

    /// The Remote's page for a tab, built from the Mac's settings.
    func remotePanel(for mode: String, builder: RemotePanelBuilder) -> RemotePanel
    /// The app's part of the Remote's iPhone page, above the iPhone list.
    func remoteSetup(builder: RemotePanelBuilder) -> [RemoteBlock]
}

extension AppModel {
    /// Shorthand for the panel: the tab a running tool keeps open.
    var lockedMode: String? { tools.lockedMode }
    /// What runs: a recording that plays or records, else the app's tool.
    var activityLine: String? { recorder.activityLine ?? tools.activityLine }
    /// Stops a playing recording and whatever of the app's runs.
    func stopActiveRun() {
        recorder.stopPlaying()
        tools.stopActiveRun()
    }
}
