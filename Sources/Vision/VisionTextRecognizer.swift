import CoreText
import CoreVideo
import Foundation
import IOSurface
import Vision

/// Sends AirPlay frames to the text recognition helper for text recognition.
/// When macOS clears Vision's model files to free disk space, the helper
/// exits and the next attempt starts a fresh one, so a run continues without
/// an app restart. Falls back to in-process recognition when the helper is
/// unavailable.
final class VisionTextRecognizer: @unchecked Sendable {
    static let shared = VisionTextRecognizer()
    /// The XPC service inside the app: its bundle ID plus ".vision".
    static let serviceName = (Bundle.main.bundleIdentifier ?? "autocore") + ".vision"

    /// A fresh helper rebuilds the model first, which takes one to two minutes on
    /// a busy Mac. Anything longer means the helper is stuck.
    private static let replyTimeout: TimeInterval = 150

    private enum Failure: Error {
        case model(String)
        case connection(String)
        case timeout
        case recognition(String)
    }

    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<[ScreenText], Failure>?
        let done = DispatchSemaphore(value: 0)

        func finish(_ result: Result<[ScreenText], Failure>) {
            lock.lock()
            let first = value == nil
            if first { value = result }
            lock.unlock()
            if first { done.signal() }
        }

        var result: Result<[ScreenText], Failure>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var restarts = 0
    private var hasConnected = false
    private var serviceUnavailable = false

    /// How often the helper was replaced; the run log reports changes.
    var restartCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return restarts
    }

    /// Whether frames reach the helper rather than the in-process fallback.
    var isUsingHelper: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasConnected && !serviceUnavailable
    }

    func recognize(_ pixelBuffer: CVPixelBuffer, languages: [String], minimumTextHeight: Double,
                   minimumConfidence: Double) throws -> [ScreenText] {
        lock.lock()
        let useService = !serviceUnavailable
        lock.unlock()
        guard useService, let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return try Self.recognizeInProcess(pixelBuffer, languages: languages,
                                               minimumTextHeight: minimumTextHeight,
                                               minimumConfidence: minimumConfidence)
        }
        var lastError: Error = Self.error("Text recognition did not start")
        var connectionFailures = 0
        for _ in 0..<3 {
            let connection = currentConnection()
            do {
                // Keep the frame alive so the decoder cannot reuse its surface
                // while the helper reads it.
                let lines = try withExtendedLifetime(pixelBuffer) {
                    try send(surface, on: connection, languages: languages,
                             minimumTextHeight: minimumTextHeight, minimumConfidence: minimumConfidence)
                }
                lock.lock()
                hasConnected = true
                lock.unlock()
                return lines
            } catch Failure.recognition(let message) {
                throw Self.error(message)
            } catch Failure.model(let message) {
                lastError = Self.error(message, code: 13)
                // The broken helper must be gone before the retry, or launchd
                // routes the next request to the same process.
                replace(connection, terminate: true)
            } catch Failure.timeout {
                lastError = Self.error("Text recognition did not answer in time")
                replace(connection, terminate: true)
            } catch Failure.connection(let message) {
                connectionFailures += 1
                lastError = Self.error(message)
                replace(connection, terminate: false)
            }
        }
        if connectionFailures == 3 {
            lock.lock()
            if !hasConnected { serviceUnavailable = true }
            lock.unlock()
            return try Self.recognizeInProcess(pixelBuffer, languages: languages,
                                               minimumTextHeight: minimumTextHeight,
                                               minimumConfidence: minimumConfidence)
        }
        throw lastError
    }

    // MARK: - Rebuilding the model files

    /// The helper's compiled model. When the Mac runs out of space, macOS
    /// deletes the files in here but keeps the folders.
    static var modelCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(serviceName)/com.apple.e5rt.e5bundlecache", isDirectory: true)
    }

    /// Whether macOS removed the model files: a model bundle is left without
    /// any file in it. No cache at all means the model was never built yet.
    static func modelFilesMissing(in cache: URL = modelCacheURL) -> Bool {
        guard let items = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: [.isRegularFileKey])
        else { return false }
        var bundles: [String] = []
        var files: [String] = []
        for case let url as URL in items {
            if url.pathExtension == "bundle" {
                bundles.append(url.path + "/")
            } else if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url.path)
            }
        }
        return bundles.contains { bundle in !files.contains { $0.hasPrefix(bundle) } }
    }

    /// Rebuild the model files on request: stop the helper, clear its cache
    /// and read a sample frame, which makes a fresh helper compile the model.
    /// Takes one to two minutes and blocks the caller.
    func rebuildModel() throws {
        lock.lock()
        let running = connection
        connection = nil
        serviceUnavailable = false
        lock.unlock()
        if let running { replace(running, terminate: true) }
        try? FileManager.default.removeItem(at: Self.modelCacheURL)
        let lines = try recognize(try Self.sampleFrame(), languages: ["de-DE", "en-US"],
                                  minimumTextHeight: 0, minimumConfidence: 0.3)
        guard lines.contains(where: { $0.normalized.contains(Self.sampleWord) }) else {
            throw Self.error("The sample text was not read back")
        }
    }

    private static let sampleWord = "erkannt"

    /// An IOSurface-backed frame like AirPlay's, with a known word.
    static func sampleFrame() throws -> CVPixelBuffer {
        let width = 750, height = 400
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else {
            throw error("The sample frame could not be created")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw error("The sample frame could not be drawn")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 48, nil)
        let text = NSAttributedString(string: "Text \(sampleWord)",
                                      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 40, y: 170)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return buffer
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let next = NSXPCConnection(serviceName: Self.serviceName)
        next.remoteObjectInterface = NSXPCInterface(with: TextRecognitionServiceProtocol.self)
        next.resume()
        connection = next
        return next
    }

    /// Drop a failed helper. The next request launches a fresh process,
    /// which rebuilds the model files macOS removed.
    private func replace(_ failed: NSXPCConnection, terminate: Bool) {
        lock.lock()
        if connection === failed {
            connection = nil
            restarts += 1
        }
        lock.unlock()
        let pid = failed.processIdentifier
        failed.invalidate()
        guard terminate, pid > 0 else { return }
        kill(pid, SIGKILL)
        for _ in 0..<60 where kill(pid, 0) == 0 { usleep(50_000) }
    }

    private func send(_ surface: IOSurface, on connection: NSXPCConnection, languages: [String],
                      minimumTextHeight: Double, minimumConfidence: Double) throws -> [ScreenText] {
        let box = ReplyBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            box.finish(.failure(.connection(error.localizedDescription)))
        }
        guard let service = proxy as? TextRecognitionServiceProtocol else {
            throw Failure.connection("Text recognition helper is unavailable")
        }
        service.recognizeText(in: surface, languages: languages, minimumTextHeight: minimumTextHeight,
                              minimumConfidence: minimumConfidence) { data, message, modelFailure in
            if let data, let lines = try? JSONDecoder().decode([VisionTextLine].self, from: data) {
                box.finish(.success(lines.map(ScreenText.init)))
            } else if modelFailure {
                box.finish(.failure(.model(message ?? "Text recognition model failed")))
            } else {
                box.finish(.failure(.recognition(message ?? "Text recognition failed")))
            }
        }
        if box.done.wait(timeout: .now() + Self.replyTimeout) == .timedOut { throw Failure.timeout }
        guard let result = box.result else { throw Failure.timeout }
        return try result.get()
    }

    private static func error(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "TextRecognition", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func recognizeInProcess(_ pixelBuffer: CVPixelBuffer, languages: [String],
                                   minimumTextHeight: Double, minimumConfidence: Double) throws -> [ScreenText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = false // Names must remain literal.
        request.minimumTextHeight = Float(minimumTextHeight)
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation -> ScreenText? in
            guard let candidate = observation.topCandidates(1).first,
                  Double(candidate.confidence) >= minimumConfidence else { return nil }
            let box = observation.boundingBox
            return ScreenText(
                value: candidate.string,
                rect: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                confidence: candidate.confidence
            )
        }
    }
}

extension ScreenText {
    init(_ line: VisionTextLine) {
        self.init(value: line.value,
                  rect: CGRect(x: line.x, y: line.y, width: line.width, height: line.height),
                  confidence: line.confidence)
    }
}
