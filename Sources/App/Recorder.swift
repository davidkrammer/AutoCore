import AppKit
import Combine
import Foundation

/// One step of a recording: what was done on the iPhone, and how long after
/// the step before it.
struct RecordedStep: Codable, Equatable, Identifiable {
    enum Action: Codable, Equatable {
        case tap(NormalizedPoint)
        case drag(from: NormalizedPoint, to: NormalizedPoint, duration: Double)
        /// Text, including keys like Return (U+000D) and Delete (U+007F).
        case type(String)
        case openApp(String)
        case home
    }

    var id = UUID()
    /// Seconds after the previous step; the first step starts at once.
    var delay: Double
    var action: Action
}

/// A saved sequence of taps, swipes and typing that can be played back.
struct Recording: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var steps: [RecordedStep]

    /// Seconds from the first step to the last.
    var duration: Double { steps.dropFirst().reduce(0) { $0 + $1.delay } }
}

/// Builds a recording while the user works: the pauses between steps, and
/// typing that arrives in pieces joined into one step.
struct RecordingDraft: Equatable {
    /// Keys typed closer together than this become one step.
    static let typingGap = 2.0
    /// Longer pauses are shortened to this.
    static let longestWait = 300.0

    private(set) var steps: [RecordedStep] = []
    let startedAt: Date
    private var lastAt: Date

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        lastAt = startedAt
    }

    mutating func add(_ action: RecordedStep.Action, at date: Date = Date()) {
        let gap = min(max(date.timeIntervalSince(lastAt), 0), Self.longestWait)
        lastAt = date
        if case let .type(text) = action, case let .type(previous)? = steps.last?.action, gap < Self.typingGap {
            steps[steps.count - 1].action = .type(previous + text)
            return
        }
        steps.append(RecordedStep(delay: steps.isEmpty ? 0 : gap, action: action))
    }
}

/// How a recording plays back.
struct PlaybackOptions: Equatable {
    /// How often; 0 repeats until stopped.
    var repeats = 1
    /// 2 plays twice as fast.
    var speed = 1.0
    /// Touches a little off and timed like a finger's, as in automations.
    var humanTouches = true

    static let repeatChoices = [1, 3, 10, 0]
    static let speedChoices = [0.5, 1.0, 2.0]

    private static var repeatsKey: String { AppBrand.key("recorder.repeats") }
    private static var speedKey: String { AppBrand.key("recorder.speed") }
    private static var humanKey: String { AppBrand.key("recorder.humanTouches") }

    /// The choice saved last, shared by all windows and the Remote.
    static var saved: PlaybackOptions {
        get {
            let defaults = AppData.preferences
            var options = PlaybackOptions()
            if let repeats = defaults.object(forKey: repeatsKey) as? Int, repeatChoices.contains(repeats) { options.repeats = repeats }
            if let speed = defaults.object(forKey: speedKey) as? Double, speedChoices.contains(speed) { options.speed = speed }
            if let human = defaults.object(forKey: humanKey) as? Bool { options.humanTouches = human }
            return options
        }
        set {
            let defaults = AppData.preferences
            defaults.set(newValue.repeats, forKey: repeatsKey)
            defaults.set(newValue.speed, forKey: speedKey)
            defaults.set(newValue.humanTouches, forKey: humanKey)
        }
    }
}

/// Carries out a step on the iPhone (the window's model; a fake in tests).
@MainActor
protocol StepPerformer: AnyObject {
    func perform(_ action: RecordedStep.Action, exact: Bool) async throws
}

/// Record and play for one window: records what is done by hand on its
/// iPhone, and plays recordings back on it.
@MainActor
final class Recorder: ObservableObject {
    enum State: Equatable { case idle, recording, playing }

    @Published private(set) var state = State.idle
    @Published private(set) var draft: RecordingDraft?
    @Published private(set) var playing: Recording?
    /// The step that plays (0-based) and the round (1-based).
    @Published private(set) var stepIndex = 0
    @Published private(set) var round = 1
    @Published private(set) var rounds = 1
    /// What the last recording or playback ended with.
    @Published private(set) var lastMessage: String?

    weak var performer: StepPerformer?
    private var task: Task<Void, Never>?

    var isRecording: Bool { state == .recording }
    var isPlaying: Bool { state == .playing }

    // MARK: Recording

    func startRecording() {
        guard state == .idle else { return }
        draft = RecordingDraft()
        lastMessage = nil
        state = .recording
    }

    /// A step done by hand; kept while recording.
    func note(_ action: RecordedStep.Action) {
        guard state == .recording else { return }
        draft?.add(action)
    }

    /// Ends the recording; saves it unless it has no steps or `save` is false.
    @discardableResult
    func stopRecording(save: Bool = true) -> Recording? {
        guard state == .recording else { return nil }
        let steps = draft?.steps ?? []
        draft = nil
        state = .idle
        guard save, !steps.isEmpty else {
            lastMessage = save ? NSLocalizedString("Nothing was recorded", comment: "Recorder") : nil
            return nil
        }
        let recording = Recording(name: RecordingLibrary.shared.nextName(), steps: steps)
        RecordingLibrary.shared.save(recording)
        lastMessage = String(format: NSLocalizedString("Saved “%@”", comment: "Recorder"), recording.name)
        return recording
    }

    // MARK: Playing

    func play(_ recording: Recording, options: PlaybackOptions = .saved) {
        guard state == .idle, !recording.steps.isEmpty, let performer else { return }
        state = .playing
        playing = recording
        stepIndex = 0
        round = 1
        rounds = options.repeats
        lastMessage = nil
        let speed = max(options.speed, 0.1)
        task = Task { [weak self] in
            var message: String
            do {
                var round = 1
                while options.repeats == 0 || round <= options.repeats {
                    self?.round = round
                    if round > 1 { try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / speed)) }
                    for (index, step) in recording.steps.enumerated() {
                        try Task.checkCancellation()
                        self?.stepIndex = index
                        if step.delay > 0 {
                            try await Task.sleep(nanoseconds: UInt64(step.delay / speed * 1_000_000_000))
                        }
                        try await performer.perform(step.action, exact: !options.humanTouches)
                    }
                    round += 1
                }
                message = String(format: NSLocalizedString("Played “%@”", comment: "Recorder"), recording.name)
            } catch is CancellationError {
                message = NSLocalizedString("Playback stopped", comment: "Recorder")
            } catch {
                message = error.localizedDescription
            }
            guard let self else { return }
            self.state = .idle
            self.playing = nil
            self.task = nil
            self.lastMessage = message
        }
    }

    func stopPlaying() {
        task?.cancel()
    }

    /// Sample recordings and states for `--ui-demo` screenshots: `recorder`
    /// (the menu), `recording` and `playing`.
    func applyDemoScenario(_ scenario: String) {
        guard AppData.isDemoProcess, ["recorder", "recording", "playing"].contains(scenario) else { return }
        let wifi = Recording(name: "Wi-Fi settings", createdAt: Date().addingTimeInterval(-7_200), steps: [
            RecordedStep(delay: 0, action: .openApp("com.apple.Preferences")),
            RecordedStep(delay: 2.1, action: .tap(NormalizedPoint(x: 0.3, y: 0.42))),
            RecordedStep(delay: 1.6, action: .drag(from: NormalizedPoint(x: 0.5, y: 0.7), to: NormalizedPoint(x: 0.5, y: 0.35),
                                                   duration: 0.35)),
            RecordedStep(delay: 1.2, action: .tap(NormalizedPoint(x: 0.3, y: 0.56))),
            RecordedStep(delay: 2.4, action: .home)])
        let note = Recording(name: "Quick note", createdAt: Date().addingTimeInterval(-86_400), steps: [
            RecordedStep(delay: 0, action: .openApp("com.apple.mobilenotes")),
            RecordedStep(delay: 1.8, action: .tap(NormalizedPoint(x: 0.88, y: 0.93))),
            RecordedStep(delay: 1.1, action: .type("Buy milk\r"))])
        for recording in [note, wifi] { RecordingLibrary.shared.save(recording) }
        switch scenario {
        case "recording":
            var sample = RecordingDraft(startedAt: Date().addingTimeInterval(-14))
            sample.add(.tap(NormalizedPoint(x: 0.3, y: 0.5)), at: Date().addingTimeInterval(-11))
            sample.add(.type("Hello"), at: Date().addingTimeInterval(-6))
            sample.add(.tap(NormalizedPoint(x: 0.5, y: 0.87)), at: Date().addingTimeInterval(-2))
            draft = sample
            state = .recording
        case "playing":
            playing = wifi
            stepIndex = 2
            round = 1
            rounds = 3
            state = .playing
        default:
            break
        }
    }

    /// The window closes: stop playing, keep what was recorded.
    func windowWillClose() {
        stopPlaying()
        stopRecording(save: true)
    }

    /// One line for the title bar and the Remote, e.g. "Playing “Login” · 3 of 8".
    var activityLine: String? {
        switch state {
        case .idle:
            return nil
        case .recording:
            return String(format: NSLocalizedString("Recording · %d steps", comment: "Recorder"), draft?.steps.count ?? 0)
        case .playing:
            guard let playing else { return nil }
            var line = String(format: NSLocalizedString("Playing “%@” · %d of %d", comment: "Recorder"),
                              playing.name, stepIndex + 1, playing.steps.count)
            if rounds != 1 {
                line += " · " + (rounds == 0
                    ? String(format: NSLocalizedString("round %d", comment: "Recorder"), round)
                    : String(format: NSLocalizedString("round %d of %d", comment: "Recorder"), round, rounds))
            }
            return line
        }
    }
}

/// The saved recordings, shared by all windows: one JSON file each in the
/// app's data folder (`recordings/`).
@MainActor
final class RecordingLibrary: ObservableObject {
    static let shared = RecordingLibrary()
    /// Newest first.
    @Published private(set) var recordings: [Recording] = []

    var folder: URL { AppData.shared.appendingPathComponent("recordings", isDirectory: true) }

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        recordings = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Recording.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ recording: Recording) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(recording).write(to: file(recording), options: .atomic)
        } catch {
            NSLog("Could not save the recording: %@", error.localizedDescription)
        }
        reload()
    }

    func rename(_ recording: Recording, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var renamed = recording
        renamed.name = String(name.prefix(60))
        save(renamed)
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: file(recording))
        reload()
    }

    func showInFinder(_ recording: Recording? = nil) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let recording {
            NSWorkspace.shared.activateFileViewerSelecting([file(recording)])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    /// "Recording 3": one more than the highest number used so far.
    func nextName() -> String {
        let prefix = NSLocalizedString("Recording", comment: "Default recording name") + " "
        let used = recordings.compactMap { $0.name.hasPrefix(prefix) ? Int($0.name.dropFirst(prefix.count)) : nil }
        return prefix + String((used.max() ?? 0) + 1)
    }

    private func file(_ recording: Recording) -> URL {
        folder.appendingPathComponent(recording.id.uuidString + ".json")
    }
}

extension AppModel: StepPerformer {
    func perform(_ action: RecordedStep.Action, exact: Bool) async throws {
        switch action {
        case let .tap(point):
            try await tap(point, exact: exact)
        case let .drag(from, to, duration):
            try await drag(from: from, to: to, duration: duration, exact: exact)
        case let .type(text):
            try await typeText(text)
        case let .openApp(bundleIdentifier):
            try await openApp(bundleIdentifier)
        case .home:
            try await goHome()
        }
    }

    /// Something done by hand: on the mirror, with the Mac keyboard, on the
    /// Remote, or with a button of the app. Becomes a step while recording.
    func manual(_ action: RecordedStep.Action) async throws {
        try await perform(action, exact: true)
        recorder.note(action)
    }
}

extension RecordedStep.Action {
    /// Short text for lists: "Tap", "Type “hello”", "Open com.apple.AppStore".
    var title: String {
        switch self {
        case .tap: return NSLocalizedString("Tap", comment: "Recorded step")
        case .drag: return NSLocalizedString("Swipe", comment: "Recorded step")
        case let .type(text): return String(format: NSLocalizedString("Type “%@”", comment: "Recorded step"), PhoneKeys.display(text))
        case let .openApp(id): return String(format: NSLocalizedString("Open %@", comment: "Recorded step"), id)
        case .home: return NSLocalizedString("Home Screen", comment: "Recorded step")
        }
    }
}
