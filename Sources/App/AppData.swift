import Foundation

/// Where the app keeps its settings and files: `~/Library/Application
/// Support/<App>` and the standard user defaults. Tests and interface demos
/// get throwaway ones.
enum AppData {
    static var isTestProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
    /// `--ui-demo <scenario>` renders the interface with sample data for
    /// screenshots. It never starts AirPlay, touch control or real runs, and
    /// uses throwaway preferences and data like the test process.
    static let isDemoProcess = CommandLine.arguments.contains("--ui-demo")
    static var demoScenario: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-demo"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static let preferences: UserDefaults = isTestProcess || isDemoProcess
        ? UserDefaults(suiteName: "autocore.tests." + UUID().uuidString)!
        : .standard
    static let shared: URL = {
        let folder = isTestProcess || isDemoProcess
            ? FileManager.default.temporaryDirectory.appendingPathComponent("\(AppBrand.current.name)Tests-" + UUID().uuidString)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(AppBrand.current.name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("Could not create the data folder: %@", error.localizedDescription)
        }
        AppBrand.current.prepareDataFolder?(folder)
        return folder
    }()

    static func file(_ name: String) -> URL {
        shared.appendingPathComponent(name)
    }
}
