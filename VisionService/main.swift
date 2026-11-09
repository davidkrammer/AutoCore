import CoreVideo
import Foundation
import IOSurface
import Vision

final class VisionService: NSObject, TextRecognitionServiceProtocol {
    func recognizeText(in surface: IOSurface, languages: [String], minimumTextHeight: Double,
                       minimumConfidence: Double,
                       reply: @escaping (Data?, String?, Bool) -> Void) {
        var unmanaged: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &unmanaged)
        guard status == kCVReturnSuccess, let pixelBuffer = unmanaged?.takeRetainedValue() else {
            reply(nil, "The AirPlay frame could not be read (\(status))", false)
            return
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = false // Names must remain literal.
        request.minimumTextHeight = Float(minimumTextHeight)
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        } catch {
            let modelFailure = VisionModelFailure.matches(error)
            if modelFailure {
                // macOS deleted the model files but kept their folders, which
                // also breaks a fresh process. Remove them so it rebuilds.
                Self.removeModelCache()
            }
            reply(nil, String(describing: error), modelFailure)
            if modelFailure {
                // This process cannot recover. Exit after the reply is sent
                // so the app's next request starts a fresh service.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
            return
        }
        let lines = (request.results ?? []).compactMap { observation -> VisionTextLine? in
            guard let candidate = observation.topCandidates(1).first,
                  Double(candidate.confidence) >= minimumConfidence else { return nil }
            let box = observation.boundingBox
            return VisionTextLine(value: candidate.string, x: box.minX, y: 1 - box.maxY,
                                  width: box.width, height: box.height, confidence: candidate.confidence)
        }
        do {
            reply(try JSONEncoder().encode(lines), nil, false)
        } catch {
            reply(nil, error.localizedDescription, false)
        }
    }

    private static func removeModelCache() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let cache = caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: TextRecognitionServiceProtocol.self)
        connection.exportedObject = VisionService()
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
