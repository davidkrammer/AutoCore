import Foundation

/// Who the app is. Every app built on AutoCore defines `AppBrand.current`
/// once (see `Demo/DemoApp.swift`).
struct AppBrand {
    /// Shown in the title bar and menus. Also names the AirPlay receivers
    /// ("<name>#1111"), the data folder and the start of every settings key.
    var name: String
    /// The iPhone app touch control works in: a new XCTest session brings it
    /// to the front. nil leaves whatever is on screen.
    var targetBundleIdentifier: String?
    /// The bundle ID WebDriverAgent gets when the app signs it for a new
    /// iPhone; nil: "<app bundle ID>.WebDriverAgentRunner".
    var runnerBundleIdentifier: String?
    /// Shown before an account name, e.g. "@" for user names.
    var accountPrefix = ""
    /// Shown while the iPhone is mirrored but the app does not know the
    /// account yet, e.g. "Detecting account"; nil shows the iPhone link.
    var detectingAccount: String?
    /// The menu's heading without an account; nil shows the iPhone's name.
    var noAccount: String?
    /// Settings keys the app kept under other names before, by core name
    /// (e.g. "wdaBaseURL": "Old.wdaBaseURL").
    var legacyKeys: [String: String] = [:]
    /// Runs once at launch with the data folder, e.g. to copy older files in.
    var prepareDataFolder: ((URL) -> Void)?
    /// Where people can support the app (e.g. GitHub Sponsors); shown in the
    /// title-bar menu when set.
    var supportURL: URL?

    /// "<name>.<key>", or the key's older name.
    static func key(_ name: String) -> String {
        current.legacyKeys[name] ?? "\(current.name).\(name)"
    }
}
