import SwiftUI

/// The title bar's record button: opens Record & Play, stops a recording
/// (and saves it), or stops a recording that plays.
struct RecorderButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: Recorder
    @State private var showMenu = AppData.demoScenario == "recorder"

    var body: some View {
        Button {
            switch recorder.state {
            case .idle: showMenu.toggle()
            case .recording: recorder.stopRecording()
            case .playing: recorder.stopPlaying()
            }
        } label: {
            Image(systemName: recorder.isRecording ? "stop.circle.fill" : recorder.isPlaying ? "stop.circle" : "record.circle")
                .foregroundStyle(recorder.isRecording ? Palette.danger : Color.primary)
                .symbolEffect(.pulse, isActive: recorder.isRecording)
        }
        .help(help)
        .accessibilityLabel(Text(help))
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            RecorderMenu(model: model, recorder: recorder) { showMenu = false }
        }
    }

    private var help: String {
        switch recorder.state {
        case .idle: return NSLocalizedString("Record & Play", comment: "Recorder button")
        case .recording: return NSLocalizedString("Stop recording and save it", comment: "Recorder button")
        case .playing: return NSLocalizedString("Stop playing", comment: "Recorder button")
        }
    }
}

/// Record & Play: start a recording, choose how recordings play, and the
/// saved recordings.
struct RecorderMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: Recorder
    @ObservedObject private var library = RecordingLibrary.shared
    let close: () -> Void
    @State private var options = PlaybackOptions.saved
    @State private var deleting: Recording?
    @State private var renaming: Recording?
    @State private var newName = ""

    private var canStart: Bool { model.controlPhase == .ready && !model.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Record & Play").font(.headline)
                Spacer()
                Button { library.showInFinder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help(NSLocalizedString("Show the recordings in Finder", comment: "Recorder"))
            }
            Button {
                recorder.startRecording()
                close()
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryActionButtonStyle(tint: Palette.danger, tintedTitle: true))
            .disabled(!canStart)
            Text("Taps, swipes and typing on the mirror, from the Mac keyboard, from the Remote and with the app's buttons are recorded, with the pauses between them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            playback
            Divider()
            list
            if let message = recorder.lastMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onChange(of: options) { _, new in PlaybackOptions.saved = new }
        .alert(Text("Delete this recording?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { library.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text(String(format: NSLocalizedString("“%@” is deleted from this Mac.", comment: "Recorder"), deleting?.name ?? ""))
        }
        .alert(Text("Rename recording"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming { library.rename(renaming, to: newName) }
                renaming = nil
            }
        }
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountMenuCaption(text: "Playback")
            Picker("Repeat", selection: $options.repeats) {
                ForEach(PlaybackOptions.repeatChoices, id: \.self) { count in
                    Text(count == 0 ? "∞" : "\(count)×").tag(count)
                }
            }
            .pickerStyle(.segmented)
            Picker("Speed", selection: $options.speed) {
                ForEach(PlaybackOptions.speedChoices, id: \.self) { speed in
                    Text(speed == 0.5 ? "½×" : "\(Int(speed))×").tag(speed)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Human-like touches", isOn: $options.humanTouches)
                .help(NSLocalizedString("Each tap lands a few points off and a moment later, like a finger. Off: exactly as recorded.", comment: "Recorder"))
        }
        .font(.callout)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            AccountMenuCaption(text: "Recordings")
            if library.recordings.isEmpty {
                Text("No recordings yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            } else {
                // A popover gives a scroll view no height of its own: room for
                // up to five rows, then it scrolls.
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(library.recordings) { recording in row(recording) }
                    }
                }
                .frame(height: min(CGFloat(library.recordings.count), 5) * Self.rowHeight)
            }
        }
    }

    private func row(_ recording: Recording) -> some View {
        HStack(spacing: 8) {
            Button {
                recorder.play(recording, options: options)
                close()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .help(NSLocalizedString("Play", comment: "Recorder"))
            VStack(alignment: .leading, spacing: 1) {
                Text(recording.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(RecorderMenu.details(recording)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                deleting = recording
            } label: {
                Image(systemName: "trash").foregroundStyle(Palette.danger)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Delete", comment: "Recorder"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename…") {
                newName = recording.name
                renaming = recording
            }
            Button("Show in Finder") { library.showInFinder(recording) }
        }
    }

    private static let rowHeight: CGFloat = 46

    /// "8 steps · 0:24".
    static func details(_ recording: Recording) -> String {
        String(format: NSLocalizedString("%d steps · %@", comment: "Recording details"),
               recording.steps.count, AppFormat.duration(recording.duration))
    }
}

/// Over the bottom of the mirror while recording or playing: what happens,
/// with Save and Discard, or Stop.
struct RecorderBar: View {
    @ObservedObject var recorder: Recorder
    @State private var discarding = false

    var body: some View {
        Group {
            switch recorder.state {
            case .idle:
                EmptyView()
            case .recording:
                capsule {
                    StatusDot(color: Palette.danger, pulsing: true)
                    Text(String(format: NSLocalizedString("%d steps", comment: "Recorder"), recorder.draft?.steps.count ?? 0))
                        .font(.system(size: 12, weight: .semibold))
                    if let start = recorder.draft?.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(AppFormat.duration(context.date.timeIntervalSince(start)))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button { discarding = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Palette.danger)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Palette.danger.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(NSLocalizedString("Discard", comment: "Recorder"))
                    pill("Save", "stop.fill", Palette.accent) { recorder.stopRecording() }
                }
                .help(NSLocalizedString("Recording", comment: "Recorder"))
            case .playing:
                capsule {
                    StatusDot(color: Palette.accent, pulsing: true)
                    Text(recorder.playing?.name ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(progress)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    pill("Stop", "stop.fill", Palette.danger) { recorder.stopPlaying() }
                }
                .help(recorder.activityLine ?? "")
            }
        }
        .alert(Text("Discard this recording?"), isPresented: $discarding) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { recorder.stopRecording(save: false) }
        } message: {
            Text("The steps recorded so far are not saved.")
        }
    }

    /// "3/5", plus the round when it repeats: "3/5 · ↻ 2/10".
    private var progress: String {
        var text = "\(recorder.stepIndex + 1)/\(recorder.playing?.steps.count ?? 0)"
        if recorder.rounds == 0 { text += " · ↻ \(recorder.round)" }
        if recorder.rounds > 1 { text += " · ↻ \(recorder.round)/\(recorder.rounds)" }
        return text
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.leading, 11)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 10)
    }

    private func pill(_ title: LocalizedStringKey, _ symbol: String, _ tint: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Recording in the menu bar's Automation menu.
struct RecorderCommands: View {
    let model: AppModel?

    var body: some View {
        if let model {
            Items(model: model, recorder: model.recorder)
        } else {
            Button("Start Recording") {}.disabled(true)
        }
    }

    private struct Items: View {
        let model: AppModel
        @ObservedObject var recorder: Recorder

        var body: some View {
            Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
                if recorder.isRecording { recorder.stopRecording() } else { recorder.startRecording() }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!recorder.isRecording && (model.controlPhase != .ready || model.isBusy))
            Button("Stop Playing") { recorder.stopPlaying() }
                .disabled(!recorder.isPlaying)
        }
    }
}
