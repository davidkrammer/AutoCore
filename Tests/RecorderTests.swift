import XCTest
@testable import AutoCore

@MainActor
final class RecorderTests: XCTestCase {
    /// Records what would be done on the iPhone.
    private final class FakePhone: StepPerformer {
        var done: [RecordedStep.Action] = []
        var exact: [Bool] = []
        func perform(_ action: RecordedStep.Action, exact: Bool) async throws {
            done.append(action)
            self.exact.append(exact)
        }
    }

    private let start = Date(timeIntervalSince1970: 1_000)
    private let a = NormalizedPoint(x: 0.2, y: 0.3)
    private let b = NormalizedPoint(x: 0.7, y: 0.8)

    func testDraftKeepsPausesAndJoinsTyping() {
        var draft = RecordingDraft(startedAt: start)
        draft.add(.tap(a), at: start.addingTimeInterval(5))
        draft.add(.type("He"), at: start.addingTimeInterval(7))
        draft.add(.type("llo"), at: start.addingTimeInterval(8))
        draft.add(.type("\r"), at: start.addingTimeInterval(11))
        draft.add(.drag(from: a, to: b, duration: 0.4), at: start.addingTimeInterval(2_000))

        XCTAssertEqual(draft.steps.map(\.action), [.tap(a), .type("Hello"), .type("\r"),
                                                  .drag(from: a, to: b, duration: 0.4)])
        // The first step starts at once; long pauses are shortened.
        XCTAssertEqual(draft.steps.map(\.delay), [0, 2, 3, RecordingDraft.longestWait])
    }

    func testRecordingsSurviveSavingAndLoading() throws {
        let recording = Recording(name: "Login", steps: [RecordedStep(delay: 0, action: .openApp("com.apple.Preferences")),
                                                         RecordedStep(delay: 1.5, action: .tap(a)),
                                                         RecordedStep(delay: 0.5, action: .home)])
        let data = try JSONEncoder().encode(recording)
        XCTAssertEqual(try JSONDecoder().decode(Recording.self, from: data), recording)
        XCTAssertEqual(recording.duration, 2)
    }

    func testOnlyARunningRecordingKeepsSteps() {
        let recorder = Recorder()
        recorder.note(.tap(a))
        XCTAssertNil(recorder.draft)
        recorder.startRecording()
        recorder.note(.tap(a))
        recorder.note(.home)
        XCTAssertEqual(recorder.draft?.steps.count, 2)
        XCTAssertNil(recorder.stopRecording(save: false))
        XCTAssertEqual(recorder.state, .idle)
    }

    func testPlaybackRepeatsTheStepsInOrder() async throws {
        let phone = FakePhone()
        let recorder = Recorder()
        recorder.performer = phone
        let recording = Recording(name: "Test", steps: [RecordedStep(delay: 0, action: .tap(a)),
                                                        RecordedStep(delay: 0.2, action: .type("x"))])
        recorder.play(recording, options: PlaybackOptions(repeats: 2, speed: 10, humanTouches: false))
        XCTAssertTrue(recorder.isPlaying)
        try await waitUntil { !recorder.isPlaying }
        XCTAssertEqual(phone.done, [.tap(a), .type("x"), .tap(a), .type("x")])
        XCTAssertEqual(phone.exact, [true, true, true, true])
        XCTAssertNil(recorder.playing)
    }

    func testStopEndsAnEndlessPlayback() async throws {
        let phone = FakePhone()
        let recorder = Recorder()
        recorder.performer = phone
        let recording = Recording(name: "Loop", steps: [RecordedStep(delay: 0.05, action: .tap(a))])
        recorder.play(recording, options: PlaybackOptions(repeats: 0, speed: 1, humanTouches: true))
        try await waitUntil { phone.done.count >= 2 }
        recorder.stopPlaying()
        try await waitUntil { !recorder.isPlaying }
        XCTAssertEqual(recorder.lastMessage, "Playback stopped")
        XCTAssertEqual(phone.exact.first, false)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition())
    }
}
