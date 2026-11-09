import AppKit
import Combine
import Foundation

/// Rebuilds the text recognition files on request after macOS deleted them
/// to free disk space. A run also does this by itself, but then pauses for
/// one to two minutes; rebuilding before a run avoids that.
@MainActor
final class TextRecognitionRepair: ObservableObject {
    static let shared = TextRecognitionRepair()

    enum State: Equatable {
        case idle
        case rebuilding(since: Date)
        case rebuilt
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// macOS removed the model files; the next recognition rebuilds them.
    @Published private(set) var filesMissing = false
    /// When the last rebuild succeeded, so an older stop no longer asks for one.
    @Published private(set) var lastRebuilt: Date?
    private var checks: AnyCancellable?

    private init() {
        guard !AppData.isDemoProcess else { return }
        refresh()
        checks = Timer.publish(every: 60, on: .main, in: .common).autoconnect().map { _ in () }
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .map { _ in () })
            .sink { [weak self] in self?.refresh() }
    }

    var isRebuilding: Bool {
        if case .rebuilding = state { return true }
        return false
    }

    func refresh() {
        guard !isRebuilding else { return }
        filesMissing = VisionTextRecognizer.modelFilesMissing()
    }

    func rebuild() {
        guard !isRebuilding else { return }
        state = .rebuilding(since: Date())
        Task.detached(priority: .userInitiated) {
            var failure: Error?
            do {
                try VisionTextRecognizer.shared.rebuildModel()
            } catch {
                failure = error
            }
            await self.finish(failure)
        }
    }

    func dismiss() {
        if !isRebuilding { state = .idle }
    }

    private func finish(_ failure: Error?) {
        filesMissing = VisionTextRecognizer.modelFilesMissing()
        if let failure {
            state = .failed(failure.localizedDescription)
            return
        }
        lastRebuilt = Date()
        state = .rebuilt
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.state == .rebuilt { self?.state = .idle }
        }
    }

    func applyDemoScenario(_ scenario: String) {
        guard AppData.isDemoProcess else { return }
        switch scenario {
        case "recognition": filesMissing = true
        case "rebuilding": state = .rebuilding(since: Date().addingTimeInterval(-23))
        default: break
        }
    }
}
