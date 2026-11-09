import CoreGraphics
import Foundation

/// One line of text recognised on the iPhone's picture.
struct ScreenText: Equatable {
    let value: String
    /// Normalized AirPlay image coordinates, origin at the upper-left.
    let rect: CGRect
    let confidence: Float

    var point: NormalizedPoint {
        NormalizedPoint(x: rect.midX, y: rect.midY).clamped
    }

    /// Lowercased, without accents or surrounding spaces, for comparing.
    var normalized: String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
