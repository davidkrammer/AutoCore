import SwiftUI

/// Settings each window keeps for itself, one window per iPhone, keyed by
/// the window's AirPlay name. A window starts from the value saved without
/// a window name, if there is one.
enum WindowSetting {
    static func key(_ base: String, window: String) -> String { "\(base).\(window)" }

    private static func start<Value>(_ base: String, _ fallback: Value) -> Value {
        AppData.preferences.object(forKey: base) as? Value ?? fallback
    }

    static func storage(_ base: String, window: String, default value: String) -> AppStorage<String> {
        AppStorage(wrappedValue: start(base, value), key(base, window: window), store: AppData.preferences)
    }

    static func storage(_ base: String, window: String, default value: Int) -> AppStorage<Int> {
        AppStorage(wrappedValue: start(base, value), key(base, window: window), store: AppData.preferences)
    }

    static func storage(_ base: String, window: String, default value: Bool) -> AppStorage<Bool> {
        AppStorage(wrappedValue: start(base, value), key(base, window: window), store: AppData.preferences)
    }
}
