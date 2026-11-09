import Foundation
import IOSurface

/// Text recognition runs in an XPC service inside the app. When macOS clears
/// Vision's compiled model cache to free disk space, recognition fails for
/// the rest of that process. A fresh service process rebuilds the model while
/// the app keeps AirPlay and touch control connected.
@objc protocol TextRecognitionServiceProtocol {
    func recognizeText(in surface: IOSurface, languages: [String], minimumTextHeight: Double,
                       minimumConfidence: Double,
                       reply: @escaping (_ lines: Data?, _ error: String?, _ modelFailure: Bool) -> Void)
}

/// One recognized line in normalized image coordinates, origin upper-left.
struct VisionTextLine: Codable, Equatable {
    let value: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Float
}

enum VisionModelFailure {
    /// Vision's errors after macOS removed its compiled model files.
    static func matches(_ error: Error) -> Bool {
        matches(String(describing: error) + " " + error.localizedDescription)
    }

    static func matches(_ description: String) -> Bool {
        description.contains("CRImageReader") || description.localizedCaseInsensitiveContains("e5rt")
    }
}
