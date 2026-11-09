import SwiftUI

/// AutoCore's own app: everything the core does, with a few tools to try it.
/// Your app replaces this folder: its `AppBrand`, its `Tools` and its tabs.
@main
struct DemoApp: App {
    var body: some Scene { AppScene() }
}

extension AppBrand {
    static let current = AppBrand(
        name: "AutoCore",
        // nil: touch control works in whatever app is on screen.
        targetBundleIdentifier: nil,
        supportURL: URL(string: "https://github.com/sponsors/davidkrammer"))
}
