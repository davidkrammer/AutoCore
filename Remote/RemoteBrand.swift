import Foundation

/// The names this Remote shows, from its Info.plist: "AutoCore Remote"
/// (CFBundleDisplayName) for the Mac app "AutoCore" (AutoCoreMacApp).
enum RemoteBrand {
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Remote"
    static let macApp = Bundle.main.object(forInfoDictionaryKey: "AutoCoreMacApp") as? String ?? "AutoCore"
}
