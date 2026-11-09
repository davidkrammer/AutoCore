import AppKit
import Combine
import SwiftUI

/// Every open window, for the second-window placement, the Remote and logs.
@MainActor
final class WindowRegistry: ObservableObject {
    static let shared = WindowRegistry()
    /// Goes up when a window opens, closes, or its iPhone, account or run changes.
    @Published private(set) var revision = 0

    private final class WeakModel {
        weak var value: AppModel?
        init(_ value: AppModel) { self.value = value }
    }

    private var windows: [ObjectIdentifier: WeakModel] = [:]
    private var observers: [ObjectIdentifier: [AnyCancellable]] = [:]

    func register(_ model: AppModel) {
        let id = ObjectIdentifier(model)
        guard windows[id] == nil else { return }
        windows[id] = WeakModel(model)
        let changed: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.revision &+= 1 }
        }
        observers[id] = [
            model.receiver.$state.removeDuplicates().sink { _ in changed() },
            model.receiver.$senderHost.removeDuplicates().sink { _ in changed() },
            model.receiver.$hasFrame.removeDuplicates().sink { _ in changed() },
            model.$controlPhase.removeDuplicates().sink { _ in changed() },
            model.$accountName.removeDuplicates().sink { _ in changed() },
            model.$accountConfirmed.removeDuplicates().sink { _ in changed() },
            model.$preferredDeviceUDID.removeDuplicates().sink { _ in changed() },
            model.tools.changes.sink { _ in changed() },
            model.recorder.$state.removeDuplicates().sink { _ in changed() },
        ]
        revision &+= 1
    }

    func unregister(_ model: AppModel) {
        let id = ObjectIdentifier(model)
        windows.removeValue(forKey: id)
        observers.removeValue(forKey: id)
        revision &+= 1
    }

    /// The other window, when exactly two are open.
    func peer(for model: AppModel) -> AppModel? {
        windows = windows.filter { $0.value.value != nil }
        let others = windows.filter { $0.key != ObjectIdentifier(model) }
        guard others.count == 1 else { return nil }
        return others.first?.value.value
    }

    var windowCount: Int { windows.values.compactMap(\.value).count }

    var models: [AppModel] {
        windows.values.compactMap(\.value).sorted { $0.receiver.receiverName < $1.receiver.receiverName }
    }
}

/// The app's windows. An app built on AutoCore only needs
/// `@main struct MyApp: App { var body: some Scene { AppScene() } }`.
struct AppScene: Scene {
    /// "autocore": every window of the app opens with this id.
    static var windowID: String { AppBrand.current.name.lowercased() }

    var body: some Scene {
        WindowGroup(Text(verbatim: AppBrand.current.name), id: Self.windowID) {
            AppWindow()
        }
        .defaultSize(width: 772, height: 760)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            AppCommands()
        }
    }
}

private struct AppWindow: View {
    @StateObject private var model = AppModel()

    var body: some View {
        if AppData.isTestProcess {
            Color.clear.frame(width: 1, height: 1)
        } else {
            ContentView(window: model.receiver.receiverName)
                .environmentObject(model)
                .focusedSceneValue(\.windowModel, model)
                .onAppear {
                    WindowRegistry.shared.register(model)
                    if AppData.isDemoProcess {
                        model.applyDemoScenario(AppData.demoScenario ?? "idle")
                    } else if !model.receiver.isRunning {
                        model.receiver.startReceiver()
                    }
                }
                .onDisappear {
                    model.closeWindow()
                    WindowRegistry.shared.unregister(model)
                }
        }
    }
}

private struct WindowModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    /// The model of the window in front, for menu commands.
    var windowModel: AppModel? {
        get { self[WindowModelKey.self] }
        set { self[WindowModelKey.self] = newValue }
    }
}

private struct AppCommands: Commands {
    @FocusedValue(\.windowModel) private var model

    var body: some Commands {
        CommandMenu("Automation") {
            Tools.commands(for: model)
            Divider()
            RecorderCommands(model: model)
        }
    }
}
