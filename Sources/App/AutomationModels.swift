import CoreGraphics
import Foundation

struct NormalizedPoint: Codable, Hashable {
    var x: Double
    var y: Double

    var clamped: NormalizedPoint {
        NormalizedPoint(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }
}

/// How the app controls the iPhone. Preview only draws the touches.
enum ControlDriver: String, CaseIterable, Identifiable {
    case webdriverAgent
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: return "Preview only"
        case .webdriverAgent: return "WebDriverAgent"
        }
    }

    var symbolName: String {
        switch self {
        case .preview: return "eye"
        case .webdriverAgent: return "iphone.gen3.radiowaves.left.and.right"
        }
    }
}
