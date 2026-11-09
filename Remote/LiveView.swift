import SwiftUI

/// The mirrored iPhone, live. A tap here is a tap there; a swipe is a swipe.
struct LiveView: View {
    @EnvironmentObject private var client: RemoteClient
    @State private var dragLine: (CGPoint, CGPoint)?
    @State private var touchStart: Date?
    @State private var ripple: Ripple?
    @State private var typing = false
    @State private var typed = ""

    struct Ripple: Identifiable, Equatable {
        let id = UUID()
        let point: CGPoint
    }

    private var window: RemoteWindow? { client.selectedSummary }

    var body: some View {
        GeometryReader { geometry in
            let aspect = window?.aspect ?? (1242.0 / 2688.0)
            let rect = Self.fit(aspect: aspect, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                Color.black
                if let frame = client.frame, client.frameWindow == window?.id {
                    Image(uiImage: frame)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityLabel(Text("Mirrored iPhone screen"))
                    if let dragLine {
                        Path { path in
                            path.move(to: dragLine.0)
                            path.addLine(to: dragLine.1)
                        }
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 5]))
                    }
                    if let ripple {
                        Circle()
                            .stroke(Palette.accent, lineWidth: 3)
                            .frame(width: 44, height: 44)
                            .position(ripple.point)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                            .id(ripple.id)
                    }
                } else {
                    placeholder
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .contentShape(Rectangle())
            .gesture(gesture(in: rect))
        }
        .overlay(alignment: .top) { runBanner }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { keyboardButton }
        }
        .alert("Type on the iPhone", isPresented: $typing) {
            TextField("Text", text: $typed)
            Button("Cancel", role: .cancel) { typed = "" }
            Button("Send") {
                client.type(typed)
                typed = ""
            }
        } message: {
            Text("Tap a text field on the iPhone first, then send the text.")
        }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 12) {
            if let window, !window.mirroring {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No iPhone in \(window.name)")
                    .font(.headline)
                Text("Connect one in the iPhone tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Loading the picture…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// What runs, with Stop, so the picture stays free for watching.
    @ViewBuilder private var runBanner: some View {
        if let status = runningStatus {
            HStack(spacing: 10) {
                StatusDot(color: Palette.tint(status.tint), pulsing: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.pill)
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(Palette.tint(status.tint))
                    Text(status.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let stop = status.actions.first(where: { $0.style == .destructive }) {
                    Button {
                        Haptics.tap()
                        client.perform(stop.id)
                    } label: {
                        Label(stop.title, systemImage: stop.symbol ?? "stop.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.danger)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 6)
        } else if let window, window.busy {
            Text("A run controls the iPhone. Stop it to tap by hand.")
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 6)
        }
    }

    private var runningStatus: RemoteStatus? {
        guard client.state?.window == window?.id else { return nil }
        for block in client.state?.panel?.blocks ?? [] {
            if case let .status(status) = block.kind, status.actions.contains(where: { $0.style == .destructive }) {
                return status
            }
        }
        return nil
    }

    private var keyboardButton: some View {
        Button {
            typing = true
        } label: {
            Image(systemName: "keyboard")
        }
        .disabled(window?.controlReady != true || window?.busy == true)
        .accessibilityLabel(Text("Type on the iPhone"))
    }

    private func gesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if touchStart == nil { touchStart = Date() }
                guard rect.contains(value.startLocation) else { return }
                if Self.distance(value.startLocation, value.location) >= 12 {
                    dragLine = (value.startLocation, value.location)
                }
            }
            .onEnded { value in
                let began = touchStart ?? Date()
                defer {
                    dragLine = nil
                    touchStart = nil
                }
                guard client.frame != nil, rect.contains(value.startLocation) else { return }
                let start = Self.normalized(value.startLocation, in: rect)
                if Self.distance(value.startLocation, value.location) < 12 {
                    Haptics.tap()
                    withAnimation(.easeOut(duration: 0.35)) { ripple = Ripple(point: value.startLocation) }
                    Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        withAnimation { ripple = nil }
                    }
                    client.tap(start)
                } else {
                    let end = Self.normalized(value.location, in: rect)
                    // As fast as the finger moved, so a flick stays a flick.
                    Haptics.tap()
                    client.drag(from: start, to: end, duration: min(1.5, max(0.15, Date().timeIntervalSince(began))))
                }
            }
    }

    static func fit(aspect: Double, in bounds: CGRect) -> CGRect {
        let inset = bounds.insetBy(dx: 10, dy: 8)
        guard aspect > 0, inset.width > 0, inset.height > 0 else { return inset }
        var width = inset.width
        var height = width / aspect
        if height > inset.height {
            height = inset.height
            width = height * aspect
        }
        return CGRect(x: inset.midX - width / 2, y: inset.minY, width: width, height: height)
    }

    static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
