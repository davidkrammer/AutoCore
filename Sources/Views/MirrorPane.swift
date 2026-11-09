import SwiftUI

/// The mirrored iPhone, edge to edge, with the connection state laid over it
/// instead of in a separate screen. Clicks and drags control the iPhone while
/// no automation runs.
struct MirrorPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var receiver: DirectAirPlayReceiver
    let onTap: (NormalizedPoint) -> Void
    let onDrag: (NormalizedPoint, NormalizedPoint) -> Void
    @State private var pendingDrag: (start: NormalizedPoint, end: NormalizedPoint)?
    @StateObject private var keyboard = PhoneKeyboard()
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let videoRect = Self.aspectFitRect(imageSize: receiver.videoSize, inside: bounds)
            ZStack(alignment: .topLeading) {
                PhoneKeyCatcher(keyboard: keyboard, onText: typeOnPhone)
                Color.black
                if receiver.hasFrame {
                    if let demoImage = Self.demoImage {
                        Image(nsImage: demoImage)
                            .resizable()
                            .frame(width: videoRect.width, height: videoRect.height)
                            .position(x: videoRect.midX, y: videoRect.midY)
                    } else {
                        MirrorRenderView(surface: receiver.renderSurface, aspectMode: .fit)
                            .frame(width: videoRect.width, height: videoRect.height)
                            .position(x: videoRect.midX, y: videoRect.midY)
                            .accessibilityLabel(Text("Mirrored iPhone screen"))
                    }
                    TouchFeedbackLayer(feedback: model.lastGesture, videoRect: videoRect)
                    if let pendingDrag {
                        Path { path in
                            path.move(to: Self.canvasPoint(pendingDrag.start, in: videoRect))
                            path.addLine(to: Self.canvasPoint(pendingDrag.end, in: videoRect))
                        }
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 5]))
                    }
                    // What a run of the app sees, e.g. the screen it recognised.
                    model.tools.mirrorOverlay()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                    if keyboard.isFocused, activeState == .key || AppData.isDemoProcess, canType {
                        PhoneKeyboardChip(keyboard: keyboard)
                            .frame(maxWidth: .infinity)
                            .padding(.top, videoRect.minY + 5)
                    }
                    if !model.isControlReady || model.receiver.state != .playing {
                        TouchBanner()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(10)
                    }
                } else {
                    MirrorInstructions(model: model, receiverName: receiver.receiverName, state: receiver.state)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(manualGesture(in: videoRect))
        }
        .task { await showDemoKeyboard() }
    }

    /// Clicking the mirror gives it the Mac keyboard, unless a run owns the iPhone.
    private var canType: Bool {
        receiver.hasFrame && receiver.state == .playing && model.controlPhase == .ready && !model.isBusy
    }

    private func typeOnPhone(_ text: String) -> Bool {
        guard canType else { return false }
        keyboard.type(text) { [model] chunk in try await model.manual(.type(chunk)) }
        return true
    }

    /// `--ui-demo keyboard` / `keyboard-typing` screenshots: focus the mirror
    /// without a click, and show keys on their way.
    private func showDemoKeyboard() async {
        guard let scenario = AppData.demoScenario, scenario.hasPrefix("keyboard") else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        keyboard.focus()
        if scenario == "keyboard-typing" {
            keyboard.type("Selii") { _ in try await Task.sleep(nanoseconds: 600_000_000_000) }
        }
    }

    private func manualGesture(in videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard receiver.hasFrame, videoRect.contains(value.startLocation),
                      Self.distance(value.startLocation, value.location) >= Self.dragThreshold(videoRect) else {
                    pendingDrag = nil
                    return
                }
                pendingDrag = (Self.normalized(value.startLocation, in: videoRect),
                               Self.normalized(value.location, in: videoRect))
            }
            .onEnded { value in
                defer { pendingDrag = nil }
                guard receiver.hasFrame, videoRect.contains(value.startLocation) else { return }
                keyboard.focus()
                let start = Self.normalized(value.startLocation, in: videoRect)
                let end = Self.normalized(value.location, in: videoRect)
                if Self.distance(value.startLocation, value.location) < Self.dragThreshold(videoRect) {
                    onTap(start)
                } else {
                    onDrag(start, end)
                }
            }
    }

    /// Stand-in mirror picture for `--ui-demo` screenshots only.
    private static let demoImage: NSImage? = {
        guard AppData.isDemoProcess,
              let index = CommandLine.arguments.firstIndex(of: "--ui-demo-image"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return NSImage(contentsOfFile: CommandLine.arguments[index + 1])
    }()

    static func aspectFitRect(imageSize: CGSize, inside bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func normalized(_ location: CGPoint, in rect: CGRect) -> NormalizedPoint {
        NormalizedPoint(x: (location.x - rect.minX) / rect.width,
                        y: (location.y - rect.minY) / rect.height).clamped
    }

    static func canvasPoint(_ point: NormalizedPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * point.clamped.x, y: rect.minY + rect.height * point.clamped.y)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
    }

    private static func dragThreshold(_ rect: CGRect) -> CGFloat {
        max(8, min(rect.width, rect.height) * 0.012)
    }
}

/// A short ripple where the app (or the user) just touched the iPhone.
private struct TouchFeedbackLayer: View {
    let feedback: TouchFeedback?
    let videoRect: CGRect
    @State private var animate = false

    var body: some View {
        ZStack {
            if let feedback, Date().timeIntervalSince(feedback.date) < 2 {
                let start = MirrorPane.canvasPoint(feedback.start, in: videoRect)
                if let endPoint = feedback.end {
                    let end = MirrorPane.canvasPoint(endPoint, in: videoRect)
                    Path { path in
                        path.move(to: start)
                        path.addLine(to: end)
                    }
                    .stroke(Palette.accent.opacity(animate ? 0 : 0.85),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    Circle()
                        .fill(Palette.accent.opacity(animate ? 0 : 0.8))
                        .frame(width: 14, height: 14)
                        .position(end)
                } else {
                    Circle()
                        .stroke(Palette.accent, lineWidth: 3)
                        .frame(width: 22, height: 22)
                        .scaleEffect(animate ? 2.2 : 0.6)
                        .opacity(animate ? 0 : 1)
                        .position(start)
                    Circle()
                        .fill(Palette.accent.opacity(animate ? 0 : 0.55))
                        .frame(width: 16, height: 16)
                        .position(start)
                }
            }
        }
        .allowsHitTesting(false)
        .id(feedback?.id)
        .onAppear { run() }
        .onChange(of: feedback?.id) { _, _ in run() }
    }

    private func run() {
        animate = false
        withAnimation(.easeOut(duration: 0.75)) { animate = true }
    }
}

/// A small label over the mirror, e.g. the screen a run recognised.
struct MirrorChip<Value: Equatable>: View {
    let text: LocalizedStringKey
    /// Animates the change when it changes.
    let value: Value

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: Palette.accent, pulsing: true)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: value)
    }
}

/// Shown on the mirror while touch control is not ready.
private struct TouchBanner: View {
    @EnvironmentObject private var model: AppModel

    private var isProblem: Bool {
        [.unlockRequired, .unavailable, .error].contains(model.controlPhase) || model.wdaRunnerIssue != nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if isProblem {
                Image(systemName: model.controlPhase == .unlockRequired ? "lock.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warning)
                    .font(.system(size: 15, weight: .semibold))
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(model.controlStatusTitle))
                    .font(.callout.weight(.semibold))
                Text(model.controlStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if model.preferredDeviceUDID.isEmpty, !model.isIdentifyingAirPlayIPhone {
                DevicePickerMenu()
            } else if isProblem || model.controlPhase == .retrying {
                Button("Retry") { model.reconnectControl() }
                    .controlSize(.small)
                    .disabled(model.isBusy)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

struct DevicePickerMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            let phones = model.discoveredIPhones.filter(\.isBooted)
            if phones.isEmpty {
                Text("No paired iPhone is available in Xcode.")
            }
            ForEach(phones) { phone in
                Button {
                    model.selectIPhoneManually(phone.hardwareUDID)
                } label: {
                    Text(phone.name)
                }
            }
            Divider()
            Button("Refresh paired iPhones") { Task { await model.refreshPairedIPhones() } }
        } label: {
            Text("Choose iPhone")
        }
        .menuStyle(.borderedButton)
        .controlSize(.small)
        .fixedSize()
        .disabled(model.isBusy)
        .task { await model.refreshPairedIPhones() }
    }
}

private struct MirrorInstructions: View {
    let model: AppModel
    let receiverName: String
    let state: DirectAirPlayState

    private var code: String { receiverName.components(separatedBy: "#").last ?? receiverName }
    private var prefix: String { receiverName.hasSuffix(code) ? String(receiverName.dropLast(code.count)) : "" }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(LocalizedStringKey(state == .connecting ? "Connecting…" : "Connect an iPhone"))
                    .font(.title2.weight(.bold))
                Text("\(AppBrand.current.name) sees the iPhone through Screen Mirroring and taps for you.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state == .connecting {
                ProgressView().controlSize(.small)
            } else {
                PhoneChooser(model: model, connector: model.phoneConnector)
                    .frame(maxWidth: 320)
            }
            // By hand: the receiver's name as the iPhone lists it, its
            // number big enough to read from across the room.
            VStack(spacing: 2) {
                Text("Or on the iPhone, choose")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.55))
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(prefix)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(code)
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .tracking(2)
                        .foregroundStyle(Palette.primaryGradient)
                        .shadow(color: Palette.accent.opacity(0.4), radius: 10)
                        .opacity(state == .connecting ? 0.75 : 1)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityElement(children: .combine)
                .textSelection(.enabled)
                Label("Control Center › Screen Mirroring", systemImage: "airplayvideo")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: 320)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.25)))
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RadialGradient(colors: [Palette.accentDeep.opacity(0.35), .black],
                           center: .top, startRadius: 10, endRadius: 520)
        }
    }
}
