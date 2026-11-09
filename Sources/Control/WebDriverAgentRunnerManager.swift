import Foundation

enum WebDriverAgentRunnerError: LocalizedError {
    case noPairedIPhone
    case ambiguousIPhones
    case selectedIPhoneUnavailable
    case bundledRunnerMissing
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPairedIPhone:
            return "No paired, available iPhone was found for WebDriverAgent."
        case .ambiguousIPhones:
            return NSLocalizedString("More than one paired iPhone is available. Choose it from the touch status in the toolbar.",
                                     comment: "Ambiguous touch device")
        case .selectedIPhoneUnavailable:
            return "This window's selected iPhone is not available to Xcode."
        case .bundledRunnerMissing:
            return "The signed WebDriverAgent runner is missing from \(AppBrand.current.name). Run scripts/build-wda.sh, then build the app again."
        case let .commandFailed(message):
            return message
        }
    }
}

/// Starts only the touch-control XCTest session. What the app does with it
/// stays behind the user's explicit buttons.
@MainActor
final class WebDriverAgentRunnerManager {
    private var runnerProcess: Process?
    /// The iPhone the runner started here belongs to.
    private(set) var runnerUDID: String?
    private var signingProcess: Process?
    private var logHandle: FileHandle?
    private var logURL: URL?

    private struct XCDevice: Decodable {
        let identifier: String
        let simulator: Bool?
        let available: Bool?
        let platform: String?
        let interface: String?
    }

    nonisolated static func onlyAvailableIPhone(in data: Data) throws -> String {
        try availableIPhone(in: data, preferredUDID: nil)
    }

    nonisolated static func availableIPhone(in data: Data, preferredUDID: String?) throws -> String {
        let devices = try JSONDecoder().decode([XCDevice].self, from: data)
        let candidates = devices.filter {
            $0.simulator == false && $0.available == true
                && $0.platform == "com.apple.platform.iphoneos"
        }
        if let preferredUDID, !preferredUDID.isEmpty {
            guard candidates.contains(where: { $0.identifier == preferredUDID }) else {
                throw WebDriverAgentRunnerError.selectedIPhoneUnavailable
            }
            return preferredUDID
        }
        let network = candidates.filter { $0.interface == "network" }
        if network.count == 1 { return network[0].identifier }
        if candidates.count == 1 { return candidates[0].identifier }
        throw candidates.isEmpty ? WebDriverAgentRunnerError.noPairedIPhone
                                 : WebDriverAgentRunnerError.ambiguousIPhones
    }

    func launchIfNeeded(preferredUDID: String?,
                        progress: @escaping @MainActor (String) -> Void = { _ in }) async throws {
        if runnerProcess?.isRunning == true { return }
        guard let archiveURL = Bundle.main.url(forResource: "WebDriverAgentProducts", withExtension: "zip") else {
            throw WebDriverAgentRunnerError.bundledRunnerMissing
        }
        let deviceJSON = try await Self.runAndCapture("/usr/bin/xcrun", ["xcdevice", "list"])
        let udid = try Self.availableIPhone(in: deviceJSON, preferredUDID: preferredUDID)
        try Task.checkCancellation()

        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let supportRoot = AppData.shared
            .appendingPathComponent("WebDriverAgent-\(build)-\(udid)", isDirectory: true)
        progress("Preparing WebDriverAgent for this iPhone…")
        let bundledTestRun = try await Task.detached(priority: .userInitiated) {
            try Self.unpackSignedRunner(archiveURL: archiveURL, into: supportRoot)
        }.value
        try Task.checkCancellation()
        let testRun = try await preparedTestRun(bundled: bundledTestRun,
                                                supportRoot: supportRoot,
                                                udid: udid,
                                                progress: progress)
        try Task.checkCancellation()

        progress("Installing and starting WebDriverAgent on the iPhone…")
        let logURL = supportRoot.appendingPathComponent("xcodebuild.log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcodebuild", "test-without-building",
            "-xctestrun", testRun.path,
            "-destination", "platform=iOS,id=\(udid)",
            "-parallel-testing-enabled", "NO",
        ]
        process.currentDirectoryURL = supportRoot
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
            runnerProcess = process
            runnerUDID = udid
            logHandle = log
            self.logURL = logURL
        } catch {
            try? log.close()
            throw error
        }
    }

    func isRunning() -> Bool { runnerProcess?.isRunning == true }

    /// The address WebDriverAgent prints once it listens on the iPhone
    /// (`ServerURLHere->http://192.168.1.20:8100<-ServerURLHere`).
    func announcedServerURL() -> String? {
        guard let logURL, let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        return Self.announcedServerURL(in: text)
    }

    /// The address a runner for this iPhone printed last, also one started
    /// by an earlier launch of the app that still runs.
    nonisolated static func announcedServerURL(forDevice udid: String) -> String? {
        let root = AppData.shared
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let logs = folders.filter { $0.lastPathComponent.hasPrefix("WebDriverAgent-") && $0.lastPathComponent.hasSuffix("-" + udid) }
            .map { $0.appendingPathComponent("xcodebuild.log") }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in logs {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            // The address is printed at the start; the log can grow large.
            let head = (try? handle.read(upToCount: 2 << 20)) ?? Data()
            if let found = announcedServerURL(in: String(decoding: head, as: UTF8.self)) { return found }
        }
        return nil
    }

    nonisolated static func announcedServerURL(in log: String) -> String? {
        guard let start = log.range(of: "ServerURLHere->", options: .backwards),
              let end = log.range(of: "<-ServerURLHere", range: start.upperBound..<log.endIndex) else { return nil }
        let url = String(log[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return url.hasPrefix("http") ? url : nil
    }

    func exitDescription() -> String? {
        guard let runnerProcess, !runnerProcess.isRunning else { return nil }
        return "WebDriverAgent test runner exited (code \(runnerProcess.terminationStatus))."
    }

    func stop() {
        if signingProcess?.isRunning == true { signingProcess?.terminate() }
        signingProcess = nil
        if runnerProcess?.isRunning == true { runnerProcess?.terminate() }
        runnerProcess = nil
        runnerUDID = nil
        try? logHandle?.close()
        logHandle = nil
    }

    /// Lets go of the runner without stopping it. WebDriverAgent stays up on
    /// the iPhone and the next connection reuses it: every new start makes
    /// iOS ask for the iPhone's passcode ("Enable UI Automation").
    func detach() {
        runnerProcess = nil
        runnerUDID = nil
        try? logHandle?.close()
        logHandle = nil
    }

    /// A bundled runner can be installed only on devices named in its Apple
    /// provisioning profile. For a newly paired iPhone, sign the bundled WDA
    /// source with this Mac's Xcode account and cache that device's products.
    private func preparedTestRun(bundled: URL, supportRoot: URL, udid: String,
                                 progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let bundledProfileURL = Self.profileURL(for: bundled)
        let bundledProfile = try await Self.decodedProfile(at: bundledProfileURL)
        if Self.profile(bundledProfile, covers: udid) { return bundled }

        let signedProducts = supportRoot.appendingPathComponent("SignedProducts", isDirectory: true)
        if let cachedRun = Self.testRun(in: signedProducts),
           let cachedProfile = try? await Self.decodedProfile(at: Self.profileURL(for: cachedRun)),
           Self.profile(cachedProfile, covers: udid) {
            return cachedRun
        }

        guard let sourceArchive = Bundle.main.url(forResource: "WebDriverAgentSource", withExtension: "zip") else {
            throw WebDriverAgentRunnerError.commandFailed(
                "This iPhone needs a newly signed WebDriverAgent, but its source is missing from \(AppBrand.current.name).")
        }
        guard let team = Self.teamIdentifier(in: bundledProfile) else {
            throw WebDriverAgentRunnerError.commandFailed(
                "\(AppBrand.current.name) could not read its Apple development team from the bundled WebDriverAgent profile.")
        }
        progress("Signing WebDriverAgent for this new iPhone with Xcode…")
        let source = supportRoot.appendingPathComponent("WebDriverAgentSource", isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            try Self.unpackSource(archiveURL: sourceArchive, into: source)
        }.value
        try Task.checkCancellation()

        let derived = supportRoot.appendingPathComponent("SigningDerivedData", isDirectory: true)
        let logURL = supportRoot.appendingPathComponent("signing-build.log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcodebuild", "build-for-testing",
            "-project", source.appendingPathComponent("WebDriverAgent.xcodeproj").path,
            "-scheme", "WebDriverAgentRunner", "-configuration", "Debug",
            "-destination", "platform=iOS,id=\(udid)",
            "-derivedDataPath", derived.path,
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            "DEVELOPMENT_TEAM=\(team)", "CODE_SIGN_STYLE=Automatic",
            "PRODUCT_BUNDLE_IDENTIFIER=" + (AppBrand.current.runnerBundleIdentifier
                ?? (Bundle.main.bundleIdentifier ?? "autocore") + ".WebDriverAgentRunner"),
            "-quiet",
        ]
        process.currentDirectoryURL = source
        process.standardOutput = log
        process.standardError = log
        try process.run()
        signingProcess = process
        defer {
            if process.isRunning { process.terminate() }
            if signingProcess === process { signingProcess = nil }
        }
        while process.isRunning {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        guard process.terminationStatus == 0 else {
            throw WebDriverAgentRunnerError.commandFailed(
                "Xcode could not sign WebDriverAgent for this iPhone (code \(process.terminationStatus)). "
                + "Check Xcode signing and \(logURL.path).")
        }
        progress("Verifying the new iPhone's signed control build…")
        let builtProducts = derived.appendingPathComponent("Build/Products", isDirectory: true)
        guard Self.testRun(in: builtProducts) != nil else {
            throw WebDriverAgentRunnerError.commandFailed(
                "Xcode finished without a WebDriverAgent test build. Check \(logURL.path).")
        }
        let pending = supportRoot.appendingPathComponent("SignedProducts.pending", isDirectory: true)
        let files = FileManager.default
        if files.fileExists(atPath: pending.path) { try files.removeItem(at: pending) }
        try files.copyItem(at: builtProducts, to: pending)
        guard let pendingRun = Self.testRun(in: pending),
              let signedProfile = try? await Self.decodedProfile(at: Self.profileURL(for: pendingRun)),
              Self.profile(signedProfile, covers: udid) else {
            throw WebDriverAgentRunnerError.commandFailed(
                "Xcode's signed WebDriverAgent profile still does not include this iPhone. Check \(logURL.path).")
        }
        if files.fileExists(atPath: signedProducts.path) { try files.removeItem(at: signedProducts) }
        try files.moveItem(at: pending, to: signedProducts)
        guard let signedRun = Self.testRun(in: signedProducts) else {
            throw WebDriverAgentRunnerError.bundledRunnerMissing
        }
        return signedRun
    }

    nonisolated static func profile(_ data: Data, covers udid: String, now: Date = Date()) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let profile = plist as? [String: Any],
              let expires = profile["ExpirationDate"] as? Date,
              expires > now else { return false }
        if profile["ProvisionsAllDevices"] as? Bool == true { return true }
        return (profile["ProvisionedDevices"] as? [String])?.contains(udid) == true
    }

    nonisolated private static func teamIdentifier(in data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let profile = plist as? [String: Any] else { return nil }
        return (profile["TeamIdentifier"] as? [String])?.first
    }

    nonisolated private static func decodedProfile(at url: URL) async throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WebDriverAgentRunnerError.bundledRunnerMissing
        }
        return try await runAndCapture("/usr/bin/security", ["cms", "-D", "-i", url.path])
    }

    nonisolated private static func profileURL(for testRun: URL) -> URL {
        testRun.deletingLastPathComponent()
            .appendingPathComponent("Debug-iphoneos/WebDriverAgentRunner-Runner.app/embedded.mobileprovision")
    }

    nonisolated private static func testRun(in products: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: products,
                                                                           includingPropertiesForKeys: nil),
              FileManager.default.fileExists(atPath: products
                .appendingPathComponent("Debug-iphoneos/WebDriverAgentRunner-Runner.app").path) else { return nil }
        return contents.first { $0.pathExtension == "xctestrun" }
    }

    nonisolated private static func unpackSource(archiveURL: URL, into root: URL) throws {
        let files = FileManager.default
        let project = root.appendingPathComponent("WebDriverAgent.xcodeproj")
        if files.fileExists(atPath: project.path) { return }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unpack.arguments = ["-x", "-k", archiveURL.path, root.path]
        unpack.standardOutput = FileHandle.nullDevice
        unpack.standardError = FileHandle.nullDevice
        try unpack.run()
        unpack.waitUntilExit()
        guard unpack.terminationStatus == 0, files.fileExists(atPath: project.path) else {
            throw WebDriverAgentRunnerError.commandFailed("Could not unpack WebDriverAgent source for Xcode signing.")
        }
    }

    nonisolated private static func runAndCapture(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: WebDriverAgentRunnerError.commandFailed(
                        "Could not list the paired iPhones (code \(finished.terminationStatus))."))
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                    if process.isRunning { process.terminate() }
                }
            }
            catch { continuation.resume(throwing: error) }
        }
    }

    nonisolated private static func unpackSignedRunner(archiveURL: URL, into root: URL) throws -> URL {
        let files = FileManager.default
        let marker = root.appendingPathComponent(".ready")
        if !files.fileExists(atPath: marker.path) {
            // This is only the app's own versioned, extracted runner cache.
            // A partial previous extraction must not be used to run a test.
            if files.fileExists(atPath: root.path) { try files.removeItem(at: root) }
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            let unpack = Process()
            unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unpack.arguments = ["-x", "-k", archiveURL.path, root.path]
            unpack.standardOutput = FileHandle.nullDevice
            unpack.standardError = FileHandle.nullDevice
            try unpack.run()
            unpack.waitUntilExit()
            guard unpack.terminationStatus == 0 else {
                throw WebDriverAgentRunnerError.commandFailed("Could not unpack the signed WebDriverAgent runner.")
            }
        }
        let products = root.appendingPathComponent("Products", isDirectory: true)
        let testRuns = try files.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctestrun" }
        guard let testRun = testRuns.first,
              files.fileExists(atPath: products.appendingPathComponent("Debug-iphoneos/WebDriverAgentRunner-Runner.app").path) else {
            throw WebDriverAgentRunnerError.bundledRunnerMissing
        }
        if !files.fileExists(atPath: marker.path) { try Data().write(to: marker) }
        return testRun
    }
}
