import CoreGraphics
import Darwin
import Foundation

enum AirPlayWDAEndpoint {
    /// The AirPlay socket supplies a numeric sender address, never a DNS name.
    /// Keep WDA's default port separate from AirPlay's receiver port.
    static func directURL(
        for senderHost: String,
        scopeID: UInt32 = 0,
        interfaceNameForIndex: (UInt32) -> String? = { index in
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard if_indextoname(index, &name) != nil else { return nil }
            return String(cString: name)
        }
    ) -> String? {
        let host = senderHost.trimmingCharacters(in: .whitespacesAndNewlines)
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return "http://\(host):8100"
        }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            guard bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 else {
                return "http://[\(host)]:8100"
            }
            // macOS may embed the receiving interface index in bytes 2–3 of a
            // link-local peer address (for example fe80:e:: on en0), but the
            // AirPlay socket also supplies it as a separate scope ID. URLSession
            // needs the unscoped address and an escaped RFC 6874 zone ID.
            let embeddedIndex = (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            let index = scopeID == 0 ? embeddedIndex : scopeID
            guard index != 0, let interface = interfaceNameForIndex(index) else { return nil }
            withUnsafeMutableBytes(of: &ipv6) { address in
                address[2] = 0
                address[3] = 0
            }
            var presentation = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &presentation,
                            socklen_t(presentation.count)) != nil else { return nil }
            return "http://[\(String(cString: presentation))%25\(interface)]:8100"
        }
        return nil
    }
}

enum WebDriverAgentError: LocalizedError {
    case invalidBaseURL
    case missingBundleIdentifier
    case missingSession
    case malformedResponse
    case server(statusCode: Int, message: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a valid WebDriverAgent or Appium URL."
        case .missingBundleIdentifier:
            return "Enter the bundle identifier of the app to launch."
        case .missingSession:
            return "No XCTest/WebDriverAgent session is connected."
        case .malformedResponse:
            return "The device driver returned an unexpected response."
        case let .server(statusCode, message):
            return "Driver error \(statusCode): \(message)"
        case let .transport(message):
            return message
        }
    }
}

struct WebDriverAgentClient {
    private let urlSession: URLSession

    init(urlSession: URLSession = URLSession(configuration: .ephemeral)) {
        self.urlSession = urlSession
    }

    func checkStatus(baseURL: String) async throws {
        let base = try parsedBaseURL(baseURL)
        let json = try await requestJSON(base: base, method: "GET", path: "status", timeout: 2)
        if let response = json as? [String: Any],
           let value = response["value"] as? [String: Any],
           let ready = value["ready"] as? Bool,
           !ready {
            throw WebDriverAgentError.transport("WebDriverAgent is starting on the iPhone.")
        }
    }

    func createSession(baseURL: String, bundleIdentifier: String) async throws -> String {
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebDriverAgentError.missingBundleIdentifier
        }
        let base = try parsedBaseURL(baseURL)
        let body = Self.sessionRequestBody(bundleIdentifier: bundleIdentifier)
        let json = try await requestJSON(base: base, method: "POST", path: "session", body: body)

        if
            let dictionary = json as? [String: Any],
            let session = dictionary["sessionId"] as? String
        {
            return session
        }
        if
            let dictionary = json as? [String: Any],
            let value = dictionary["value"] as? [String: Any],
            let session = value["sessionId"] as? String
        {
            return session
        }
        throw WebDriverAgentError.malformedResponse
    }

    func deleteSession(baseURL: String, sessionID: String) async throws {
        guard !sessionID.isEmpty else { return }
        let base = try parsedBaseURL(baseURL)
        _ = try await requestJSON(base: base, method: "DELETE",
                                  path: "session/\(sessionID)", timeout: 2)
    }

    /// Only call this for an XCTest runner launched by this app itself.
    func shutdown(baseURL: String) async throws {
        let base = try parsedBaseURL(baseURL)
        _ = try await requestJSON(base: base, method: "POST", path: "wda/shutdown", timeout: 2)
    }

    /// An empty `bundleIdentifier` attaches to whatever is on screen.
    static func sessionRequestBody(bundleIdentifier: String) -> [String: Any] {
        guard !bundleIdentifier.isEmpty else {
            return ["capabilities": ["alwaysMatch": ["platformName": "iOS", "appium:automationName": "XCUITest"],
                                     "firstMatch": [[:]]],
                    "desiredCapabilities": [:] as [String: Any]]
        }
        return [
            "capabilities": [
                "alwaysMatch": [
                    "platformName": "iOS",
                    "appium:automationName": "XCUITest",
                    "appium:bundleId": bundleIdentifier,
                    // WDA otherwise terminates an already-running app when
                    // a session is created. Attach to its current process.
                    "appium:forceAppLaunch": false,
                    "appium:shouldTerminateApp": false
                ],
                "firstMatch": [[:]]
            ],
            "desiredCapabilities": [
                "bundleId": bundleIdentifier,
                "forceAppLaunch": false,
                "shouldTerminateApp": false
            ]
        ]
    }

    func viewportSize(baseURL: String, sessionID: String) async throws -> CGSize {
        guard !sessionID.isEmpty else { throw WebDriverAgentError.missingSession }
        let base = try parsedBaseURL(baseURL)
        let json = try await requestJSON(
            base: base,
            method: "GET",
            path: "session/\(sessionID)/window/size"
        )
        guard
            let dictionary = json as? [String: Any],
            let value = dictionary["value"] as? [String: Any],
            let width = number(value["width"]),
            let height = number(value["height"])
        else {
            throw WebDriverAgentError.malformedResponse
        }
        return CGSize(width: width, height: height)
    }

    func directViewportSize(baseURL: String) async throws -> CGSize {
        let base = try parsedBaseURL(baseURL)
        let json = try await requestJSON(
            base: base,
            method: "GET",
            path: "wda/screen",
            timeout: 2
        )
        guard
            let dictionary = json as? [String: Any],
            let value = dictionary["value"] as? [String: Any],
            let screenSize = value["screenSize"] as? [String: Any],
            let width = number(screenSize["width"]),
            let height = number(screenSize["height"])
        else {
            throw WebDriverAgentError.malformedResponse
        }
        return CGSize(width: width, height: height)
    }

    func tap(
        normalizedPoint: NormalizedPoint,
        holdMilliseconds: Int = 55,
        viewport: CGSize,
        baseURL: String,
        sessionID: String
    ) async throws {
        let base = try parsedBaseURL(baseURL)
        let point = normalizedPoint.clamped
        let x = Int(round(point.x * max(viewport.width - 1, 1)))
        let y = Int(round(point.y * max(viewport.height - 1, 1)))
        let body: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": x, "y": y, "origin": "viewport"],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": holdMilliseconds],
                    ["type": "pointerUp", "button": 0]
                ]
            ]]
        ]
        _ = try await requestJSON(
            base: base,
            method: "POST",
            path: sessionID.isEmpty ? "wda/absolute-actions" : "session/\(sessionID)/actions",
            body: body
        )
    }

    /// WebDriverAgent's idle waits: `animationCoolOffTimeout` (after every
    /// touch request, default 2 s) and `waitForIdleTimeout` (default 10 s).
    func idleWaits(baseURL: String, sessionID: String) async throws -> (coolOff: Double, idle: Double) {
        let base = try parsedBaseURL(baseURL)
        let json = try await requestJSON(base: base, method: "GET", path: "session/\(sessionID)/appium/settings")
        let value = (json as? [String: Any])?["value"] as? [String: Any] ?? [:]
        return ((value["animationCoolOffTimeout"] as? NSNumber)?.doubleValue ?? 2,
                (value["waitForIdleTimeout"] as? NSNumber)?.doubleValue ?? 10)
    }

    func setIdleWaits(coolOff: Double, idle: Double, baseURL: String, sessionID: String) async throws {
        let base = try parsedBaseURL(baseURL)
        _ = try await requestJSON(base: base, method: "POST", path: "session/\(sessionID)/appium/settings",
                                  body: ["settings": ["animationCoolOffTimeout": coolOff, "waitForIdleTimeout": idle]])
    }

    /// One tap of a burst: where, how long the finger stays down, and the
    /// rest before the next tap.
    struct BurstTap: Equatable {
        var point: NormalizedPoint
        var holdMilliseconds: Int
        var gapMilliseconds: Int
    }

    /// Several taps in one request, so they follow each other at their own
    /// rhythm instead of waiting for a round trip each.
    func tapBurst(
        _ taps: [BurstTap],
        viewport: CGSize,
        baseURL: String,
        sessionID: String
    ) async throws {
        let base = try parsedBaseURL(baseURL)
        var actions: [[String: Any]] = []
        for tap in taps {
            let point = viewportPoint(for: tap.point, viewport: viewport)
            actions += [
                ["type": "pointerMove", "duration": 0, "x": point.x, "y": point.y, "origin": "viewport"],
                ["type": "pointerDown", "button": 0],
                ["type": "pause", "duration": tap.holdMilliseconds],
                ["type": "pointerUp", "button": 0],
                ["type": "pause", "duration": tap.gapMilliseconds],
            ]
        }
        let body: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger",
                "parameters": ["pointerType": "touch"],
                "actions": actions
            ]]
        ]
        _ = try await requestJSON(
            base: base,
            method: "POST",
            path: sessionID.isEmpty ? "wda/absolute-actions" : "session/\(sessionID)/actions",
            body: body
        )
    }

    func drag(
        from normalizedStartPoint: NormalizedPoint,
        to normalizedEndPoint: NormalizedPoint,
        duration: Double,
        releaseHold: Double = 0,
        viewport: CGSize,
        baseURL: String,
        sessionID: String
    ) async throws {
        let base = try parsedBaseURL(baseURL)
        let start = viewportPoint(for: normalizedStartPoint, viewport: viewport)
        let end = viewportPoint(for: normalizedEndPoint, viewport: viewport)
        let gestureDuration = min(max(duration, 0.10), 10)
        // A pause before lifting the finger leaves no release velocity, so a
        // scroll list stops exactly where the drag ended instead of flinging.
        let hold: [[String: Any]] = releaseHold > 0
            ? [["type": "pause", "duration": Int(round(min(releaseHold, 2) * 1_000))]] : []
        let body: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": start.x, "y": start.y, "origin": "viewport"],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 100],
                    [
                        "type": "pointerMove",
                        "duration": Int(round(gestureDuration * 1_000)),
                        "x": end.x,
                        "y": end.y,
                        "origin": "viewport"
                    ]
                ] + hold + [
                    ["type": "pointerUp", "button": 0]
                ]
            ]]
        ]

        if sessionID.isEmpty {
            _ = try await requestJSON(
                base: base,
                method: "POST",
                path: "wda/absolute-actions",
                body: body
            )
        } else {
            do {
                _ = try await requestJSON(
                    base: base,
                    method: "POST",
                    path: "session/\(sessionID)/actions",
                    body: body
                )
            } catch let error as WebDriverAgentError where shouldTryLegacyGestureEndpoint(after: error) {
                let legacyBody: [String: Any] = [
                    "fromX": start.x,
                    "fromY": start.y,
                    "toX": end.x,
                    "toY": end.y,
                    "duration": max(gestureDuration, 0.5)
                ]
                _ = try await requestJSON(
                    base: base,
                    method: "POST",
                    path: "session/\(sessionID)/wda/dragfromtoforduration",
                    body: legacyBody
                )
            }
        }
    }

    func typeText(_ text: String, baseURL: String, sessionID: String) async throws {
        guard !sessionID.isEmpty else { throw WebDriverAgentError.missingSession }
        let base = try parsedBaseURL(baseURL)
        _ = try await requestJSON(
            base: base,
            method: "POST",
            path: "session/\(sessionID)/wda/keys",
            body: ["value": [text]]
        )
    }

    /// Brings an installed iPhone app to the front, launching it if needed.
    func activateApp(_ bundleIdentifier: String, baseURL: String, sessionID: String) async throws {
        guard !sessionID.isEmpty else { throw WebDriverAgentError.missingSession }
        let base = try parsedBaseURL(baseURL)
        _ = try await requestJSON(base: base, method: "POST", path: "session/\(sessionID)/wda/apps/activate",
                                  body: ["bundleId": bundleIdentifier])
    }

    /// The Home button: back to the Home Screen.
    func pressHome(baseURL: String) async throws {
        let base = try parsedBaseURL(baseURL)
        _ = try await requestJSON(base: base, method: "POST", path: "wda/homescreen")
    }

    /// Read-only foreground check. Unlike createSession, this never launches
    /// the app after the user has switched away from it.
    func activeAppBundleIdentifier(baseURL: String, sessionID: String) async throws -> String {
        guard !sessionID.isEmpty else { throw WebDriverAgentError.missingSession }
        let base = try parsedBaseURL(baseURL)
        let json = try await requestJSON(
            base: base,
            method: "GET",
            path: "session/\(sessionID)/wda/activeAppInfo",
            // A busy game can keep XCTest's accessibility snapshot busy for
            // about five seconds after a heavy animation. A three-second
            // deadline falsely reports a disconnected control session.
            timeout: 8
        )
        guard let dictionary = json as? [String: Any],
              let value = dictionary["value"] as? [String: Any],
              let bundleID = value["bundleId"] as? String else {
            throw WebDriverAgentError.malformedResponse
        }
        return bundleID
    }

    // MARK: - Without AirPlay

    /// A session that attaches to whatever is on screen and launches nothing,
    /// for Control Center while no AirPlay picture exists yet.
    func createPlainSession(baseURL: String) async throws -> String {
        let base = try parsedBaseURL(baseURL)
        let body: [String: Any] = ["capabilities": ["alwaysMatch": [String: Any](), "firstMatch": [[String: Any]()]]]
        let json = try await requestJSON(base: base, method: "POST", path: "session", body: body)
        if let dictionary = json as? [String: Any] {
            if let session = dictionary["sessionId"] as? String { return session }
            if let value = dictionary["value"] as? [String: Any], let session = value["sessionId"] as? String {
                return session
            }
        }
        throw WebDriverAgentError.malformedResponse
    }

    /// The iPhone's name, when iOS tells it (often just "iPhone").
    func deviceName(baseURL: String) async throws -> String? {
        let base = try parsedBaseURL(baseURL)
        let json = try await requestJSON(base: base, method: "GET", path: "wda/device/info", timeout: 3)
        return ((json as? [String: Any])?["value"] as? [String: Any])?["name"] as? String
    }

    func isLocked(baseURL: String) async throws -> Bool {
        let base = try parsedBaseURL(baseURL)
        let json = try await requestJSON(base: base, method: "GET", path: "wda/locked", timeout: 5)
        return ((json as? [String: Any])?["value"] as? Bool) ?? false
    }

    /// Screen size in points and the status bar height (44 or more on
    /// iPhones without a Home button).
    func screenInfo(baseURL: String) async throws -> (size: CGSize, statusBarHeight: CGFloat) {
        let base = try parsedBaseURL(baseURL)
        let json = try await requestJSON(base: base, method: "GET", path: "wda/screen", timeout: 5)
        guard let value = (json as? [String: Any])?["value"] as? [String: Any],
              let screen = value["screenSize"] as? [String: Any],
              let width = number(screen["width"]), let height = number(screen["height"]) else {
            throw WebDriverAgentError.malformedResponse
        }
        let statusBar = (value["statusBarSize"] as? [String: Any]).flatMap { number($0["height"]) } ?? 0
        return (CGSize(width: width, height: height), statusBar)
    }

    func screenshotPNG(baseURL: String) async throws -> Data {
        let base = try parsedBaseURL(baseURL)
        let json = try await requestJSON(base: base, method: "GET", path: "screenshot", timeout: 15)
        guard let text = (json as? [String: Any])?["value"] as? String,
              let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
            throw WebDriverAgentError.malformedResponse
        }
        return data
    }

    /// Frames, in points, of the elements matching an NSPredicate in the app
    /// in front (SpringBoard while Control Center is open).
    func elementFrames(predicate: String, baseURL: String, sessionID: String) async throws -> [CGRect] {
        guard !sessionID.isEmpty else { throw WebDriverAgentError.missingSession }
        let base = try parsedBaseURL(baseURL)
        let json = try await requestJSON(base: base, method: "POST", path: "session/\(sessionID)/elements",
                                         body: ["using": "predicate string", "value": predicate], timeout: 10)
        guard let elements = (json as? [String: Any])?["value"] as? [[String: Any]] else { return [] }
        var frames: [CGRect] = []
        for element in elements {
            guard let id = (element["ELEMENT"] ?? element["element-6066-11e4-a52e-4f735466cecf"]) as? String,
                  let rectJSON = try? await requestJSON(base: base, method: "GET",
                                                        path: "session/\(sessionID)/element/\(id)/rect", timeout: 5),
                  let rect = (rectJSON as? [String: Any])?["value"] as? [String: Any],
                  let x = number(rect["x"]), let y = number(rect["y"]),
                  let width = number(rect["width"]), let height = number(rect["height"]) else { continue }
            frames.append(CGRect(x: x, y: y, width: width, height: height))
        }
        return frames
    }

    /// One tap at a point given in iPhone points.
    func tap(at point: CGPoint, baseURL: String, sessionID: String) async throws {
        guard !sessionID.isEmpty else { throw WebDriverAgentError.missingSession }
        let base = try parsedBaseURL(baseURL)
        let body: [String: Any] = [
            "actions": [[
                "type": "pointer", "id": "finger", "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(point.x.rounded()), "y": Int(point.y.rounded()),
                     "origin": "viewport"],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 60],
                    ["type": "pointerUp", "button": 0],
                ],
            ]],
        ]
        _ = try await requestJSON(base: base, method: "POST", path: "session/\(sessionID)/actions", body: body)
    }

    /// One swipe between two points given in iPhone points.
    func swipe(from start: CGPoint, to end: CGPoint, duration: Double, baseURL: String, sessionID: String) async throws {
        guard !sessionID.isEmpty else { throw WebDriverAgentError.missingSession }
        let base = try parsedBaseURL(baseURL)
        let body: [String: Any] = [
            "actions": [[
                "type": "pointer", "id": "finger", "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(start.x.rounded()), "y": Int(start.y.rounded()),
                     "origin": "viewport"],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 60],
                    ["type": "pointerMove", "duration": Int((duration * 1_000).rounded()),
                     "x": Int(end.x.rounded()), "y": Int(end.y.rounded()), "origin": "viewport"],
                    ["type": "pointerUp", "button": 0],
                ],
            ]],
        ]
        _ = try await requestJSON(base: base, method: "POST", path: "session/\(sessionID)/actions", body: body)
    }

    private func parsedBaseURL(_ string: String) throws -> URL {
        guard
            let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme,
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            throw WebDriverAgentError.invalidBaseURL
        }
        return url
    }

    private func requestJSON(
        base: URL,
        method: String,
        path: String,
        body: [String: Any]? = nil,
        timeout: TimeInterval = 12
    ) async throws -> Any {
        var url = base
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let statusCode: Int
        do {
            let (responseData, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WebDriverAgentError.malformedResponse
            }
            data = responseData
            statusCode = http.statusCode
        } catch let error as URLError where error.code == .notConnectedToInternet {
            // Some macOS builds mark URLSession's path offline despite a
            // granted Local Network permission. curl uses the same direct
            // device URL and only runs for this specific transport failure.
            (data, statusCode) = try await Self.requestUsingCurl(request, timeout: timeout)
        }
        let json = data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)

        guard (200..<300).contains(statusCode) else {
            let message = serverMessage(from: json) ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw WebDriverAgentError.server(statusCode: statusCode, message: message)
        }
        return json
    }

    private static func requestUsingCurl(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, Int) {
        guard let url = request.url else { throw WebDriverAgentError.invalidBaseURL }
        return try await withCheckedThrowingContinuation { continuation in
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("wda-\(UUID().uuidString).json")
            let process = Process()
            let statusPipe = Pipe()
            let errorPipe = Pipe()
            let inputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            var arguments = [
                "--silent", "--show-error", "--max-time", String(Int(ceil(timeout))),
                "--output", outputURL.path, "--write-out", "%{http_code}",
                "--request", request.httpMethod ?? "GET",
                "--header", "Accept: application/json"
            ]
            if request.httpBody != nil {
                arguments += ["--header", "Content-Type: application/json", "--data-binary", "@-"]
                process.standardInput = inputPipe
            }
            arguments.append(url.absoluteString)
            process.arguments = arguments
            process.standardOutput = statusPipe
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let data = (try? Data(contentsOf: outputURL)) ?? Data()
                try? FileManager.default.removeItem(at: outputURL)
                let statusText = String(decoding: statusPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0, let status = Int(statusText) else {
                    continuation.resume(throwing: WebDriverAgentError.transport(
                        errorText.isEmpty ? "Could not reach iPhone touch control." : errorText
                    ))
                    return
                }
                continuation.resume(returning: (data, status))
            }
            do {
                try process.run()
                if let body = request.httpBody {
                    try? inputPipe.fileHandleForWriting.write(contentsOf: body)
                    try? inputPipe.fileHandleForWriting.close()
                }
            } catch {
                process.terminationHandler = nil
                try? FileManager.default.removeItem(at: outputURL)
                continuation.resume(throwing: error)
            }
        }
    }

    private func number(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
        if let double = value as? Double { return CGFloat(double) }
        if let int = value as? Int { return CGFloat(int) }
        return nil
    }

    private func viewportPoint(
        for normalizedPoint: NormalizedPoint,
        viewport: CGSize
    ) -> (x: Int, y: Int) {
        let point = normalizedPoint.clamped
        return (
            x: Int(round(point.x * max(viewport.width - 1, 1))),
            y: Int(round(point.y * max(viewport.height - 1, 1)))
        )
    }

    private func shouldTryLegacyGestureEndpoint(after error: WebDriverAgentError) -> Bool {
        guard case let .server(statusCode, message) = error else { return false }
        let normalizedMessage = message.lowercased()
        return [404, 405, 501].contains(statusCode)
            || normalizedMessage.contains("unknown command")
            || normalizedMessage.contains("unsupported")
    }

    private func serverMessage(from json: Any) -> String? {
        guard let dictionary = json as? [String: Any] else { return nil }
        if let message = dictionary["message"] as? String { return message }
        if
            let value = dictionary["value"] as? [String: Any],
            let message = value["message"] as? String
        {
            return message
        }
        return nil
    }
}
