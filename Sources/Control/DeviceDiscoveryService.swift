import AppKit
import CoreGraphics
import Darwin
import Foundation

struct PairedIPhone: Identifiable, Equatable, Sendable {
    let id: String
    let hardwareUDID: String
    let name: String
    let osVersion: String
    let isBooted: Bool
    let developerModeEnabled: Bool?
    let lastConnection: Date?
    /// "iPhone XS", from Xcode.
    var modelName = ""
    /// "network" or "wired".
    var transport = ""

    var subtitle: String {
        osVersion.isEmpty ? "Paired iPhone" : "iOS \(osVersion)"
    }
}

enum DeviceDiscoveryError: LocalizedError {
    case commandFailed(String)
    case malformedResponse
    case malformedDisplay

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return detail.isEmpty ? "Could not inspect paired iPhones." : detail
        case .malformedResponse:
            return "Xcode returned an unreadable device list."
        case .malformedDisplay:
            return "Xcode could not read the iPhone display size."
        }
    }
}

struct DeviceDiscoveryService: Sendable {
    func discoverIPhones() async throws -> [PairedIPhone] {
        let result = try await Self.runDeviceList()
        guard result.status == 0 else {
            throw DeviceDiscoveryError.commandFailed(
                result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try Self.parseIPhones(from: result.output)
    }

    func logicalDisplaySize(for hardwareUDID: String) async throws -> CGSize {
        let result = try await Self.runDeviceCommand(
            ["device", "info", "displays", "--device", hardwareUDID],
            outputPrefix: "display"
        )
        guard result.status == 0 else {
            throw DeviceDiscoveryError.commandFailed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try Self.parseLogicalDisplaySize(from: result.output)
    }

    static func parseLogicalDisplaySize(from data: Data) throws -> CGSize {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let displays = result["displays"] as? [[String: Any]],
              let display = displays.first(where: { $0["primary"] as? Bool == true }) ?? displays.first,
              let nativeSize = display["nativeSize"] as? [NSNumber], nativeSize.count == 2,
              let scale = display["pointScale"] as? NSNumber, scale.doubleValue > 0 else {
            throw DeviceDiscoveryError.malformedDisplay
        }
        let width = nativeSize[0].doubleValue / scale.doubleValue
        let height = nativeSize[1].doubleValue / scale.doubleValue
        guard width > 0, height > 0 else { throw DeviceDiscoveryError.malformedDisplay }
        return CGSize(width: width, height: height)
    }

    static func parseIPhones(from data: Data) throws -> [PairedIPhone] {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let devices = result["devices"] as? [[String: Any]]
        else {
            throw DeviceDiscoveryError.malformedResponse
        }

        return devices.compactMap { device in
            guard
                let properties = device["properties"] as? [String: Any],
                let hardware = properties["hardware"] as? [String: Any],
                hardware["reality"] as? String == "physical",
                hardware["deviceType"] as? String == "iPhone",
                let hardwareUDID = hardware["udid"] as? String,
                !hardwareUDID.isEmpty,
                let identifier = device["identifier"] as? String
            else {
                return nil
            }

            let state = properties["state"] as? [String: Any]
            let software = properties["software"] as? [String: Any]
            let connection = properties["connection"] as? [String: Any]
            let version = software?["osVersionNumber"] as? [String: Any]
            let developerMode = state?["developerModeStatus"] as? [String: Any]
            let developerModeEnabled: Bool?
            if let developerMode {
                developerModeEnabled = developerMode["enabled"] != nil
            } else {
                developerModeEnabled = nil
            }

            let lastConnection: Date?
            if let seconds = connection?["lastConnectionDate"] as? TimeInterval {
                lastConnection = Date(timeIntervalSinceReferenceDate: seconds)
            } else if let number = connection?["lastConnectionDate"] as? NSNumber {
                lastConnection = Date(timeIntervalSinceReferenceDate: number.doubleValue)
            } else {
                lastConnection = nil
            }

            return PairedIPhone(
                id: identifier,
                hardwareUDID: hardwareUDID,
                name: state?["name"] as? String ?? hardware["marketingName"] as? String ?? "iPhone",
                osVersion: version?["stringValue"] as? String ?? "",
                isBooted: state?["bootState"] as? String == "booted",
                developerModeEnabled: developerModeEnabled,
                lastConnection: lastConnection,
                modelName: hardware["marketingName"] as? String ?? "",
                transport: connection?["transportType"] as? String ?? ""
            )
        }
        .sorted { lhs, rhs in
            if lhs.isBooted != rhs.isBooted { return lhs.isBooted }
            return (lhs.lastConnection ?? .distantPast) > (rhs.lastConnection ?? .distantPast)
        }
    }

    private struct CommandResult: Sendable {
        let status: Int32
        let output: Data
        let error: String
    }

    private static func runDeviceList() async throws -> CommandResult {
        try await runDeviceCommand(["list", "devices"], outputPrefix: "devices")
    }

    private static func runDeviceCommand(_ command: [String], outputPrefix: String) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let errorPipe = Pipe()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(outputPrefix)-\(UUID().uuidString).json")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "devicectl",
                "--quiet",
                "--timeout", "8",
                "--json-output", outputURL.path,
                "--omit-deprecated-fields-in-json"
            ] + command
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let output = (try? Data(contentsOf: outputURL)) ?? Data()
                try? FileManager.default.removeItem(at: outputURL)
                let error = String(
                    decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
                continuation.resume(
                    returning: CommandResult(
                        status: process.terminationStatus,
                        output: output,
                        error: error
                    )
                )
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// AirPlay supplies an IP address, while CoreDevice supplies a paired device
/// name. Resolve the sender's Bonjour/PTR name and require one exact canonical
/// name match; a shared name or missing PTR must not select the wrong phone.
enum AirPlayDeviceIdentity {
    static func reverseDNSName(for senderHost: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard senderHost.withCString({ getaddrinfo($0, nil, &hints, &result) }) == 0,
              let result else { return nil }
        defer { freeaddrinfo(result) }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(result.pointee.ai_addr, result.pointee.ai_addrlen,
                          &name, socklen_t(name.count), nil, 0, NI_NAMEREQD) == 0 else {
            return nil
        }
        return String(cString: name)
    }

    static func matchedIPhone(forBonjourName bonjourName: String?,
                              in phones: [PairedIPhone]) -> PairedIPhone? {
        guard let bonjourName, !bonjourName.isEmpty else { return nil }
        let canonicalHost = canonical(bonjourName.replacingOccurrences(
            of: #"\.local\.?$"#, with: "", options: [.regularExpression, .caseInsensitive]
        ))
        guard !canonicalHost.isEmpty else { return nil }
        let matches = phones.filter { canonical($0.name) == canonicalHost }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func canonical(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined().lowercased()
    }
}

@MainActor
enum DeviceHubLauncher {
    static func bundleURL(forDeveloperDirectory developerDirectory: String) -> URL {
        URL(fileURLWithPath: developerDirectory, isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent("Applications/DeviceHub.app", isDirectory: true)
    }

    static func open() -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let developerDirectory = String(
                    decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !developerDirectory.isEmpty {
                    let bundleURL = bundleURL(forDeveloperDirectory: developerDirectory)
                    if FileManager.default.fileExists(atPath: bundleURL.path),
                       NSWorkspace.shared.open(bundleURL) {
                        return true
                    }
                }
            }
        }
        guard let registeredURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.dt.Devices"
        ) else { return false }
        return NSWorkspace.shared.open(registeredURL)
    }
}

enum DeviceControlRetryPolicy {
    static func delaySeconds(afterFailure attempt: Int) -> Int {
        let delays = [2, 5, 10, 30]
        return delays[min(max(attempt - 1, 0), delays.count - 1)]
    }
}
