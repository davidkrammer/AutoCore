import CoreVideo
import Foundation
import ImageIO

enum PhoneMirrorError: LocalizedError {
    case touchUnavailable
    case locked
    case controlCenterClosed
    case receiverMissing(String)
    case noPicture

    var errorDescription: String? {
        switch self {
        case .touchUnavailable:
            return NSLocalizedString("Touch control did not start. Is the iPhone unlocked and on the same Wi-Fi?",
                                     comment: "Mirror connect error")
        case .locked:
            return NSLocalizedString("The iPhone is locked. Unlock it, then try again.", comment: "Mirror connect error")
        case .controlCenterClosed:
            return NSLocalizedString("Control Center did not open on the iPhone.", comment: "Mirror connect error")
        case let .receiverMissing(name):
            return String(format: NSLocalizedString("%@ was not in the iPhone's Screen Mirroring list.",
                                                    comment: "Mirror connect error"), name)
        case .noPicture:
            return NSLocalizedString("The iPhone did not start mirroring.", comment: "Mirror connect error")
        }
    }
}

/// Starts Screen Mirroring from the Mac, so nobody has to pick up the
/// iPhone: through touch control (WebDriverAgent, which works without
/// AirPlay) it opens Control Center, taps Screen Mirroring and chooses this
/// window's receiver. The iPhone has to be unlocked.
@MainActor
final class PhoneMirrorConnector: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    private let client = WebDriverAgentClient()
    private var task: Task<Bool, Never>?


    /// The iPhone being connected, when one was chosen from the list.
    @Published private(set) var connectingDevice: String?

    /// `phone` nil: the iPhone this window used last (reconnects after an
    /// update or a dropped picture).
    @discardableResult
    func connect(model: AppModel, phone: PairedIPhone? = nil, automatic: Bool = false) async -> Bool {
        if let task { return await task.value }
        connectingDevice = phone?.hardwareUDID
        defer { connectingDevice = nil }
        let task = Task { await self.run(model: model, phone: phone, automatic: automatic) }
        self.task = task
        let connected = await task.value
        self.task = nil
        return connected
    }

    private func run(model: AppModel, phone: PairedIPhone?, automatic: Bool) async -> Bool {
        let receiver = model.receiver
        guard !AppData.isDemoProcess, receiver.state != .playing else { return true }
        let name = receiver.receiverName
        log("Connecting \(name)\(automatic ? " by itself" : "")\(phone.map { " to \($0.name)" } ?? "")")
        do {
            for _ in 0..<20 where !receiver.isRunning {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            show(NSLocalizedString("Reaching the iPhone…", comment: "Mirror connect status"))
            let base: String
            if let phone {
                model.expectMirror(from: phone.hardwareUDID)
                base = try await model.touchEndpoint(for: phone) { [weak self] message in self?.show(message) }
            } else {
                base = try await model.touchEndpointWithoutAirPlay { [weak self] message in self?.show(message) }
            }
            log("Touch control at \(base)")
            if (try? await client.isLocked(baseURL: base)) == true { throw PhoneMirrorError.locked }
            ccBase = base
            ccSession = try await client.createPlainSession(baseURL: base)
            let screen = try await client.screenInfo(baseURL: base)
            let size = screen.size
            guard receiver.state != .playing else { return finish() }

            // Control Center has pages (controls, music, connections); a
            // pull from the top can land on any of them. Only the first one
            // has the Screen Mirroring tile.
            show(NSLocalizedString("Opening Control Center…", comment: "Mirror connect status"))
            var tile: CGPoint?
            var listOpen = false
            var pulls = 0
            for _ in 0..<6 where tile == nil && !listOpen {
                switch await controlCenterState(size: size, receiverName: name) {
                case let .firstPage(point):
                    tile = point
                case .mirroringList:
                    listOpen = true
                case .otherPage:
                    log("Control Center is on another page; back to the first")
                    try await pageBack(size: size)
                case .closed:
                    guard pulls < 2 else { break }
                    pulls += 1
                    try await openControlCenter(size: size, homeButton: screen.statusBarHeight < 30)
                }
            }
            if let tile {
                show(NSLocalizedString("Tapping Screen Mirroring…", comment: "Mirror connect status"))
                try await cc { try await self.client.tap(at: tile, baseURL: base, sessionID: $0) }
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } else if !listOpen {
                await closeControlCenter(size: size, receiverName: name)
                throw PhoneMirrorError.controlCenterClosed
            }

            show(String(format: NSLocalizedString("Choosing %@…", comment: "Mirror connect status"), name))
            guard let row = try await receiverRow(name: name, size: size, base: base) else {
                await closeControlCenter(size: size, receiverName: name)
                throw PhoneMirrorError.receiverMissing(name)
            }
            try await cc { try await self.client.tap(at: row, baseURL: base, sessionID: $0) }

            // Close Control Center as soon as the iPhone connects, while this
            // session still exists (the app's own one replaces it soon after).
            show(NSLocalizedString("Waiting for the iPhone picture…", comment: "Mirror connect status"))
            for _ in 0..<30 where receiver.state != .connecting && receiver.state != .playing {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            show(NSLocalizedString("Closing Control Center…", comment: "Mirror connect status"))
            await closeControlCenter(size: size, receiverName: name)
            for _ in 0..<40 where receiver.state != .playing {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard receiver.state == .playing else { throw PhoneMirrorError.noPicture }
            log("Mirroring")
            await confirmClosed(model: model, size: size, receiverName: name)
            return finish()
        } catch is CancellationError {
            if receiver.state != .playing { model.expectMirror(from: nil) }
            phase = .idle
            return false
        } catch {
            if receiver.state != .playing { model.expectMirror(from: nil) }
            let message = error.localizedDescription
            log("Failed: \(message)")
            phase = .failed(message)
            return false
        }
    }

    private func finish() -> Bool {
        log("Done")
        phase = .idle
        return true
    }

    // MARK: - Control Center

    private enum ControlCenterState {
        case closed
        case firstPage(tile: CGPoint)
        case mirroringList
        case otherPage
    }

    private var ccBase = ""
    private var ccSession = ""

    /// Runs a request on the plain session Control Center needs. The app's
    /// own session is tied to its iPhone app and does not see SpringBoard; when
    /// it replaces this one (WebDriverAgent keeps one), start a new one.
    private func cc<T>(_ body: (String) async throws -> T) async throws -> T {
        do {
            return try await body(ccSession)
        } catch let WebDriverAgentError.server(status, _) where status == 404 {
            ccSession = try await client.createPlainSession(baseURL: ccBase)
            return try await body(ccSession)
        }
    }

    private func frames(_ predicate: String) async -> [CGRect] {
        (try? await cc { try await self.client.elementFrames(predicate: predicate, baseURL: self.ccBase, sessionID: $0) }) ?? []
    }

    /// Where Control Center stands, from the accessibility tree (only the
    /// page on screen is in it). WebDriverAgent calls the identifier `name`.
    private func controlCenterState(size: CGSize, receiverName: String) async -> ControlCenterState {
        let quoted = receiverName.replacingOccurrences(of: "'", with: "\\'")
        let list = await frames("label CONTAINS[c] 'synchronisierung stoppen' OR label CONTAINS[c] 'stop mirroring' "
                                + "OR label CONTAINS[c] '\(quoted)'")
        // The list's rows and its stop button span the panel; the receiver's
        // name in the small music tile does not.
        if list.contains(where: { $0.width > size.width * 0.7 }) {
            return .mirroringList
        }
        if let tile = await mirroringTile(size: size) { return .firstPage(tile: tile) }
        let anyPage = await frames("name BEGINSWITH 'ccui-' OR name BEGINSWITH 'cc-' OR name IN "
                                   + "{'wifi-button', 'airplane-mode-button', 'bluetooth-button', 'mru-router-upper', 'focus-modes-ui'}")
        return anyPage.isEmpty ? .closed : .otherPage
    }

    private func openControlCenter(size: CGSize, homeButton: Bool) async throws {
        // A short pull: a long one runs on into the next page.
        if homeButton {
            try await cc { try await self.client.swipe(from: CGPoint(x: size.width / 2, y: size.height - 2),
                                                       to: CGPoint(x: size.width / 2, y: size.height * 0.6),
                                                       duration: 0.3, baseURL: self.ccBase, sessionID: $0) }
        } else {
            // Face ID iPhones: down from the top right corner.
            try await cc { try await self.client.swipe(from: CGPoint(x: size.width - 30, y: 2),
                                                       to: CGPoint(x: size.width - 30, y: size.height * 0.32),
                                                       duration: 0.3, baseURL: self.ccBase, sessionID: $0) }
        }
        try await Task.sleep(nanoseconds: 1_300_000_000)
    }

    /// Down along the empty left edge: one page back, touching no control.
    private func pageBack(size: CGSize) async throws {
        try await cc { try await self.client.swipe(from: CGPoint(x: 8, y: size.height * 0.37),
                                                   to: CGPoint(x: 8, y: size.height * 0.8),
                                                   duration: 0.3, baseURL: self.ccBase, sessionID: $0) }
        try await Task.sleep(nanoseconds: 1_200_000_000)
    }

    /// The Screen Mirroring tile, from the accessibility tree only, and only
    /// when it lies on screen: a guessed place once opened Apple Music.
    private func mirroringTile(size: CGSize) async -> CGPoint? {
        let found = await frames("type == 'XCUIElementTypeButton' AND (label CONTAINS[c] 'synchronisierung' "
                                 + "OR label CONTAINS[c] 'mirroring' OR name CONTAINS[c] 'mirroring') AND NOT (label CONTAINS[c] 'stop')")
        let screen = CGRect(origin: .zero, size: size)
        guard let frame = found.first(where: {
            $0.width >= 30 && $0.height >= 30 && $0.width < size.width * 0.9 && screen.contains(CGPoint(x: $0.midX, y: $0.midY))
        }) else { return nil }
        log("Screen Mirroring tile at \(Int(frame.midX)),\(Int(frame.midY))")
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func receiverRow(name: String, size: CGSize, base: String) async throws -> CGPoint? {
        let quoted = name.replacingOccurrences(of: "'", with: "\\'")
        for attempt in 0..<8 {
            try Task.checkCancellation()
            if let frame = await frames("label CONTAINS[c] '\(quoted)'").first(where: { $0.width > 0 && $0.height > 0 }) {
                log("\(name) row at \(Int(frame.midX)),\(Int(frame.midY))")
                return CGPoint(x: frame.midX, y: frame.midY)
            }
            if attempt >= 1, let point = await readOnScreen(name, size: size, base: base) {
                log("\(name) read on the iPhone screenshot at \(Int(point.x)),\(Int(point.y))")
                return point
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return nil
    }

    /// Text recognition on WebDriverAgent's screenshot, for when the
    /// accessibility tree has no row.
    private func readOnScreen(_ text: String, size: CGSize, base: String) async -> CGPoint? {
        guard let png = try? await client.screenshotPNG(baseURL: base) else { return nil }
        let wanted = Self.compact(text)
        let texts: [ScreenText] = await Task.detached(priority: .userInitiated) {
            guard let buffer = Self.pixelBuffer(png: png) else { return [] }
            return (try? VisionTextRecognizer.shared.recognize(buffer, languages: ["de-DE", "en-US"],
                                                               minimumTextHeight: 0.008,
                                                               minimumConfidence: 0.3)) ?? []
        }.value
        guard let match = texts.first(where: { Self.compact($0.value).contains(wanted) }) else { return nil }
        return CGPoint(x: match.rect.midX * size.width, y: match.rect.midY * size.height)
    }

    /// Closes Control Center from wherever it stands: below the tiles on its
    /// first page or the mirroring list (empty there), back a page anywhere
    /// else. The tree decides every step, so no tap lands in an app.
    private func closeControlCenter(size: CGSize, receiverName: String) async {
        for _ in 0..<6 {
            switch await controlCenterState(size: size, receiverName: receiverName) {
            case .closed:
                log("Control Center closed")
                return
            case .firstPage, .mirroringList:
                _ = try? await cc { try await self.client.tap(at: CGPoint(x: size.width / 2, y: size.height * 0.88),
                                                              baseURL: self.ccBase, sessionID: $0) }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            case .otherPage:
                try? await pageBack(size: size)
            }
        }
        log("Control Center may still be open")
    }

    /// With the picture back, check it for Control Center once more.
    private func confirmClosed(model: AppModel, size: CGSize, receiverName: String) async {
        let terms = ["bildschirmsynchronisierung", "synchronisierung stoppen", "screen mirroring", "stop mirroring",
                     "spielmodus", "game mode", "fokus", "focus", "sim fehlt", "no sim", "flugmodus", "airplane mode",
                     "andere lautsprecher", "other speakers"]
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let frame = model.receiver.currentPixelBuffer(),
              let texts = try? await Task.detached(priority: .userInitiated, operation: {
                  try VisionTextRecognizer.shared.recognize(frame, languages: ["de-DE", "en-US"],
                                                            minimumTextHeight: 0.008, minimumConfidence: 0.3)
              }).value else { return }
        let showsControlCenter = texts.map(\.normalized).contains { text in terms.contains { text.contains($0) } }
        guard showsControlCenter else { return }
        log("The picture still shows Control Center")
        await closeControlCenter(size: size, receiverName: receiverName)
    }

    // MARK: - Helpers

    private func show(_ message: String) {
        phase = .working(message)
    }

    private func log(_ message: String) {
        let url = AppData.shared.appendingPathComponent("mirroring.log")
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    nonisolated static func compact(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { !$0.isWhitespace }
    }

    nonisolated static func pixelBuffer(png: Data) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}
