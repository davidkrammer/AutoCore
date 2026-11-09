import Foundation

/// Free space on the Mac's data volume. Below about 12 GB macOS starts
/// clearing app caches, including Vision's text recognition model files.
enum DiskSpace {
    static let lowThreshold: Int64 = 15_000_000_000

    static func availableBytes(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return nil }
        return Int64(capacity)
    }

    static func isLow(_ bytes: Int64?) -> Bool {
        bytes.map { $0 < lowThreshold } ?? false
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
