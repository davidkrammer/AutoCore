import Foundation

/// A log file in the app's data folder that every window writes to. One copy
/// of its newest lines lives here and the file is rewritten whole, so two
/// windows running at once never overwrite each other's lines. With more
/// than one window open, each line names the account (or AirPlay name) it
/// comes from.
@MainActor
final class RunLogFile {
    private static var files: [String: RunLogFile] = [:]

    static func named(_ name: String, limit: Int = 400) -> RunLogFile {
        if let file = files[name] { return file }
        let file = RunLogFile(url: AppData.file(name), limit: limit)
        files[name] = file
        return file
    }

    let url: URL
    private(set) var lines: [String]
    private let limit: Int

    init(url: URL, limit: Int = 400) {
        self.url = url
        self.limit = limit
        lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Adds one line and returns it as written.
    @discardableResult
    func append(_ message: String, from model: AppModel?) -> String {
        let line = Self.line(message, tag: model?.logTag, at: Date())
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        save()
        return line
    }

    func replace(with lines: [String]) {
        self.lines = Array(lines.suffix(limit))
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Could not save %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    nonisolated static func line(_ message: String, tag: String?, at date: Date) -> String {
        let time = ISO8601DateFormatter().string(from: date)
        guard let tag, !tag.isEmpty else { return "\(time)  \(message)" }
        return "\(time)  [\(tag)] \(message)"
    }
}

extension AppModel {
    /// Names this window in shared logs, only while more than one is open.
    var logTag: String? {
        guard WindowRegistry.shared.windowCount > 1 else { return nil }
        return accountName.map { "@" + $0 } ?? receiver.receiverName
    }
}
