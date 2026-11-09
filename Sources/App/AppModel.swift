import AppKit
import Combine
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum DeviceControlPhase: Equatable {
    case searching
    case connecting
    case ready
    case unlockRequired
    case retrying
    case unavailable
    case error
    case preview
}

/// How touches reach the iPhone: WebDriverAgent, an XCTest runner on it.
enum ActiveControlTransport: Equatable {
    case webdriverAgent

    var title: String { "WebDriverAgent" }
}

/// The last automation touch, drawn briefly over the mirror so a run is
/// visibly doing what its status says.
struct TouchFeedback: Equatable, Identifiable {
    let id = UUID()
    let start: NormalizedPoint
    let end: NormalizedPoint?
    let date = Date()
}

enum DeviceMatchSource: Equatable {
    case bonjour
    case remembered
    case onlyPhone
    case manual

    var title: String {
        switch self {
        case .bonjour: return "Matched from AirPlay"
        case .remembered: return "Remembered from last time"
        case .onlyPhone: return "Only available iPhone"
        case .manual: return "Selected manually"
        }
    }
}

/// How the window knows the account signed in on its iPhone.
enum AccountSource: Equatable {
    case detected
    case remembered
    case manual
}

enum ControlError: LocalizedError {
    case noPairedIPhone

    var errorDescription: String? {
        switch self {
        case .noPairedIPhone:
            return "No available paired iPhone was found."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let windowID = UUID()
    let receiver = DirectAirPlayReceiver()
    /// The app's own tools for this window: its tabs and automations.
    private(set) var tools: Tools!
    /// Record and play on this window's iPhone.
    let recorder = Recorder()
    private var recorderObserver: AnyCancellable?

    @Published var driver: ControlDriver {
        didSet {
            guard driver != oldValue else { return }
            AppData.preferences.set(driver.rawValue, forKey: Self.driverDefaultsKey)
            restartControlSupervisor()
        }
    }

    @Published var preferredDeviceUDID: String {
        didSet {
            guard preferredDeviceUDID != oldValue else { return }
            if !preferredDeviceUDID.isEmpty {
                AppData.preferences.set(preferredDeviceUDID, forKey: lastTouchDeviceKey)
            }
            activeIPhone = nil
            guard receiver.state == .playing else { return }
            applyRememberedAccount()
            wdaRunnerIssue = nil
            releaseAirPlayControl(switchingTo: preferredDeviceUDID)
            invalidateWDASession()
            restartControlSupervisor()
            startWDARunnerIfNeeded()
        }
    }

    @Published var wdaBaseURL: String {
        didSet {
            AppData.preferences.set(wdaBaseURL, forKey: Self.wdaURLDefaultsKey)
            if wdaBaseURL != oldValue {
                invalidateWDASession()
            }
        }
    }
    @Published var useAirPlayWDAAddress: Bool {
        didSet {
            guard useAirPlayWDAAddress != oldValue else { return }
            AppData.preferences.set(useAirPlayWDAAddress, forKey: Self.autoWDAAddressDefaultsKey)
            if useAirPlayWDAAddress, receiver.state == .playing,
               let host = receiver.senderHost {
                applyAirPlayWDAAddress(host)
            }
        }
    }
    /// The app touch control opens; empty keeps whatever is on screen.
    var wdaBundleIdentifier: String { AppBrand.current.targetBundleIdentifier ?? "" }
    @Published var wdaSessionID = ""
    @Published private(set) var wdaViewport: CGSize?

    @Published private(set) var discoveredIPhones: [PairedIPhone] = []
    @Published private(set) var deviceDiscoveryIssue: String?
    @Published private(set) var isIdentifyingAirPlayIPhone = false
    @Published private(set) var didAutoMatchAirPlayIPhone = false
    @Published private(set) var activeIPhone: PairedIPhone?
    @Published private(set) var activeControlTransport: ActiveControlTransport?
    @Published private(set) var controlPhase: DeviceControlPhase = .searching
    @Published private(set) var controlDetail = "Finding a paired iPhone…"
    @Published private(set) var controlRetryCount = 0
    @Published private(set) var isStartingWDARunner = false
    @Published private(set) var wdaRunnerProgress = "Starting iPhone touch control…"
    @Published private(set) var wdaRunnerIssue: String?
    /// The account signed in on the iPhone, when the app knows it (it may
    /// read it from the screen). Shown in the title bar and the Remote.
    @Published var accountName: String?
    @Published var accountConfirmed = false
    @Published var accountSource: AccountSource?
    @Published private(set) var deviceMatchSource: DeviceMatchSource?
    @Published var lastGesture: TouchFeedback?

    private let wdaClient = WebDriverAgentClient()
    private let wdaRunnerManager = WebDriverAgentRunnerManager()
    private let deviceDiscovery = DeviceDiscoveryService()
    /// Starts Screen Mirroring on the iPhone from the Mac.
    let phoneConnector = PhoneMirrorConnector()
    /// The window showing this iPhone, to open a second one beside it.
    weak var hostWindow: NSWindow?
    private var mirrorHeartbeatTask: Task<Void, Never>?
    private var portraitWatchTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Set while the app quits, so the end of mirroring is not taken as the
    /// iPhone stopping it.
    static var isTerminating = false
    private var controlSupervisorTask: Task<Void, Never>?
    private var controlSupervisorID = UUID()
    private var airPlayStateObserver: AnyCancellable?
    private var wdaStartupTask: Task<Void, Never>?
    private var wdaStartupID = UUID()
    private var wdaSessionCreationTask: Task<String, Error>?
    private var wdaSessionGeneration = UUID()
    private var wasAirPlayPlaying = false
    private var wdaReleaseTask: Task<Void, Never>?
    private var airPlayDeviceIdentityTask: Task<Void, Never>?
    private var airPlayDeviceIdentityID = UUID()

    private static let driverDefaultsKey = AppBrand.key("controlDriver")
    private static let wdaURLDefaultsKey = AppBrand.key("wdaBaseURL")
    private static let autoWDAAddressDefaultsKey = AppBrand.key("useAirPlayWDAAddress")
    private static let airPlayDevicesDefaultsKey = AppBrand.key("airPlayDeviceMemory")
    private static let deviceAccountsDefaultsKey = AppBrand.key("deviceAccountMemory")

    init() {
        let defaults = AppData.preferences
        // One supported control path: the signed XCTest runner on the
        // mirrored iPhone.
        driver = .webdriverAgent
        // Device selection belongs to this window, never to a global default:
        // two AirPlay windows may control different paired iPhones at once.
        preferredDeviceUDID = ""
        wdaBaseURL = AppData.isDemoProcess ? "http://127.0.0.1:9"
            : defaults.string(forKey: Self.wdaURLDefaultsKey) ?? "http://127.0.0.1:8100"
        useAirPlayWDAAddress = true
        tools = Tools(model: self)
        recorder.performer = self
        recorderObserver = recorder.$state.removeDuplicates().sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        airPlayStateObserver = receiver.$state.removeDuplicates().sink { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.receiver.state == state,
                      !AppData.isDemoProcess else { return }
                if state == .playing, let host = self.receiver.senderHost {
                    if !self.wasAirPlayPlaying {
                        self.wasAirPlayPlaying = true
                        self.reconnectTask?.cancel()
                        self.reconnectTask = nil
                        self.startMirrorHeartbeat()
                        self.accountConfirmed = false
                        self.tools.mirrorStarted()
                    }
                    self.applyAirPlayWDAAddress(host)
                    self.identifyAirPlayIPhone(host: host)
                } else if state != .playing {
                    self.cancelAirPlayDeviceIdentity()
                    if self.wasAirPlayPlaying {
                        self.wasAirPlayPlaying = false
                        self.accountConfirmed = false
                        self.releaseAirPlayControl()
                        self.invalidateWDASession()
                        self.tools.mirrorStopped()
                        self.stopMirrorHeartbeat()
                        self.reconnectForWaitingRun()
                    }
                    self.preferredDeviceUDID = ""
                    self.didAutoMatchAirPlayIPhone = false
                    self.deviceMatchSource = nil
                    self.wdaStartupID = UUID()
                    self.wdaStartupTask?.cancel()
                    self.wdaStartupTask = nil
                    self.isStartingWDARunner = false
                    self.activeControlTransport = nil
                    self.controlPhase = .searching
                    self.controlDetail = "Waiting for iPhone AirPlay…"
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            // Demo and test hosts must never talk to a real iPhone.
            guard !AppData.isDemoProcess, !AppData.isTestProcess else { return }
            self?.restartControlSupervisor()
            self?.reconnectAfterRelaunch()
        }
    }

    /// Sample state for interface screenshots (`--ui-demo <scenario>`).
    func applyDemoScenario(_ scenario: String) {
        guard AppData.isDemoProcess else { return }
        let mirrored = !["disconnected", "first-launch", "menu-off"].contains(scenario)
        receiver.applyDemoMirror(mirrored)
        let phone = PairedIPhone(id: "demo", hardwareUDID: "00008020-DEMO", name: "iPhone XS",
                                 osVersion: "18.6", isBooted: true, developerModeEnabled: true,
                                 lastConnection: Date(), modelName: "iPhone XS")
        discoveredIPhones = [phone,
                             PairedIPhone(id: "demo2", hardwareUDID: "00008150-DEMO", name: "iPhone 17 Pro Max",
                                          osVersion: "27.1", isBooted: true, developerModeEnabled: true,
                                          lastConnection: Date(), modelName: "iPhone 17 Pro Max"),
                             PairedIPhone(id: "demo3", hardwareUDID: "00008140-DEMO", name: "iPhone 16 Pro Max",
                                          osVersion: "26.2", isBooted: false, developerModeEnabled: true,
                                          lastConnection: nil, modelName: "iPhone 16 Pro Max")]
        if mirrored {
            preferredDeviceUDID = phone.hardwareUDID
            deviceMatchSource = .remembered
            activeIPhone = phone
        }
        if scenario == "touch" {
            controlPhase = .connecting
            isStartingWDARunner = true
            wdaRunnerProgress = "Starting touch control on iPhone XS…"
            activeControlTransport = nil
        } else if mirrored {
            controlPhase = .ready
            activeControlTransport = .webdriverAgent
            controlDetail = "WebDriverAgent · 375×812 pt"
        } else {
            controlPhase = .searching
            controlDetail = "Waiting for iPhone AirPlay…"
        }
        TextRecognitionRepair.shared.applyDemoScenario(scenario)
        recorder.applyDemoScenario(scenario)
        tools.applyDemoScenario(scenario)
    }

    deinit {
        controlSupervisorTask?.cancel()
        wdaStartupTask?.cancel()
        wdaReleaseTask?.cancel()
        airPlayDeviceIdentityTask?.cancel()
    }


    var controlStatusTitle: String {
        if receiver.state != .playing { return "Waiting for AirPlay" }
        if controlPhase != .ready && isStartingWDARunner { return "Starting touch" }
        switch controlPhase {
        case .searching: return "Finding iPhone"
        case .connecting: return "Connecting"
        case .ready: return "Control ready"
        case .unlockRequired: return "Unlock iPhone"
        case .retrying: return "Touch offline"
        case .unavailable: return "No iPhone"
        case .error: return "Control issue"
        case .preview: return "Preview"
        }
    }

    var controlStatusSymbol: String {
        if controlPhase != .ready && isStartingWDARunner {
            return "arrow.trianglehead.2.clockwise.rotate.90"
        }
        switch controlPhase {
        case .searching, .connecting, .retrying: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .ready: return "hand.tap.fill"
        case .unlockRequired: return "lock.open"
        case .unavailable, .error: return "exclamationmark.triangle.fill"
        case .preview: return "eye"
        }
    }

    var controlStatusDetail: String {
        if controlPhase == .ready { return controlDetail }
        if isStartingWDARunner { return wdaRunnerProgress }
        return wdaRunnerIssue ?? controlDetail
    }

    var isControlReady: Bool {
        controlPhase == .ready || controlPhase == .preview
    }

    var isControlBusy: Bool {
        [.searching, .connecting, .retrying].contains(controlPhase)
    }

    func refreshPairedIPhones() async {
        guard !AppData.isDemoProcess else { return }
        do {
            discoveredIPhones = try await deviceDiscovery.discoverIPhones()
            deviceDiscoveryIssue = nil
            if receiver.state == .playing, preferredDeviceUDID.isEmpty,
               !isIdentifyingAirPlayIPhone, let host = receiver.senderHost {
                identifyAirPlayIPhone(host: host, phones: discoveredIPhones)
            }
        } catch {
            deviceDiscoveryIssue = error.localizedDescription
        }
    }

    func selectIPhoneManually(_ hardwareUDID: String) {
        cancelAirPlayDeviceIdentity()
        didAutoMatchAirPlayIPhone = false
        deviceMatchSource = hardwareUDID.isEmpty ? nil : .manual
        if let host = receiver.senderHost, !hardwareUDID.isEmpty {
            rememberDevice(hardwareUDID, forAirPlayHost: host)
        }
        preferredDeviceUDID = hardwareUDID
    }

    /// Phones that another window already controls.
    var devicesUsedByOtherWindows: Set<String> {
        Set(WindowRegistry.shared.models.filter { $0 !== self }
            .map(\.preferredDeviceUDID).filter { !$0.isEmpty })
    }

    private func rememberedDevice(forAirPlayHost host: String) -> String? {
        let memory = AppData.preferences.dictionary(forKey: Self.airPlayDevicesDefaultsKey)
        return memory?[host] as? String
    }

    private func rememberDevice(_ hardwareUDID: String, forAirPlayHost host: String) {
        var memory = AppData.preferences.dictionary(forKey: Self.airPlayDevicesDefaultsKey) ?? [:]
        memory[host] = hardwareUDID
        AppData.preferences.set(memory, forKey: Self.airPlayDevicesDefaultsKey)
    }

    private func rememberedAccount(forDevice hardwareUDID: String) -> String? {
        guard !hardwareUDID.isEmpty else { return nil }
        let memory = AppData.preferences.dictionary(forKey: Self.deviceAccountsDefaultsKey)
        return memory?[hardwareUDID] as? String
    }

    /// Notes the account an iPhone uses, so the window knows it at once
    /// next time.
    func rememberAccount(_ name: String, forDevice hardwareUDID: String) {
        guard !hardwareUDID.isEmpty else { return }
        var memory = AppData.preferences.dictionary(forKey: Self.deviceAccountsDefaultsKey) ?? [:]
        memory[hardwareUDID] = name
        AppData.preferences.set(memory, forKey: Self.deviceAccountsDefaultsKey)
    }

    /// A known iPhone starts with the account it used last time, so a run
    /// can start at once. The app may still read the account from the
    /// screen and replace it.
    private func applyRememberedAccount() {
        if accountConfirmed, accountSource != .remembered, let name = accountName {
            rememberAccount(name, forDevice: preferredDeviceUDID)
            return
        }
        guard !accountConfirmed, let name = rememberedAccount(forDevice: preferredDeviceUDID),
              tools.activateAccount(name) else { return }
        accountSource = .remembered
    }


    /// A tap from an automation, a few points off and after a short random
    /// moment like a finger's (`HumanTouch`); `exact` for taps made by hand.
    func tap(_ point: NormalizedPoint, exact: Bool = false) async throws {
        var target = point
        var hold = Self.tapHoldMilliseconds
        if !exact {
            var random = SystemRandomNumberGenerator()
            target = HumanTouch.point(point, screen: wdaViewport, using: &random)
            hold = HumanTouch.milliseconds(hold, using: &random)
            try await Task.sleep(nanoseconds: UInt64(HumanTouch.reaction(using: &random) * 1_000_000_000))
        }
        guard receiver.state == .playing, driver != .preview, controlPhase == .ready else {
            throw NSError(domain: AppBrand.current.name, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "AirPlay or iPhone touch control disconnected"])
        }
        try await executeTap(target, holdMilliseconds: hold)
        lastGesture = TouchFeedback(start: target, end: nil)
    }

    nonisolated static let tapHoldMilliseconds = 55

    private var savedIdleWaits: (coolOff: Double, idle: Double)?

    /// After every touch request WebDriverAgent waits up to 2 s for the app
    /// to stop animating, and some apps (games) never do. Fast tools switch
    /// those waits off while they run and restore them afterwards. Reapplied per
    /// fight, since a new WebDriverAgent session resets them.
    func setQuickTouches(_ quick: Bool) async {
        guard driver == .webdriverAgent,
              !wdaSessionID.isEmpty else { return }
        do {
            if quick {
                if savedIdleWaits == nil {
                    savedIdleWaits = try await wdaClient.idleWaits(baseURL: wdaBaseURL, sessionID: wdaSessionID)
                }
                try await wdaClient.setIdleWaits(coolOff: 0, idle: 0, baseURL: wdaBaseURL, sessionID: wdaSessionID)
            } else if let saved = savedIdleWaits {
                savedIdleWaits = nil
                try await wdaClient.setIdleWaits(coolOff: saved.coolOff, idle: saved.idle,
                                                 baseURL: wdaBaseURL, sessionID: wdaSessionID)
            }
        } catch {
            NSLog("Could not change WebDriverAgent idle waits: %@", error.localizedDescription)
        }
    }

    /// Quick taps for fast attacks: one WebDriverAgent request plays them
    /// all, about seven a second by default, each a few points off and held
    /// and spaced a little differently.
    func tapBurst(_ points: [NormalizedPoint], holdMilliseconds: Int = 45,
                      gapMilliseconds: Int = 75) async throws {
        guard receiver.state == .playing, driver != .preview, controlPhase == .ready else {
            throw NSError(domain: AppBrand.current.name, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "AirPlay or iPhone touch control disconnected"])
        }
        var random = SystemRandomNumberGenerator()
        let taps = points.map {
            WebDriverAgentClient.BurstTap(point: HumanTouch.point($0, screen: wdaViewport, using: &random),
                                          holdMilliseconds: HumanTouch.milliseconds(holdMilliseconds, using: &random),
                                          gapMilliseconds: HumanTouch.milliseconds(gapMilliseconds, using: &random))
        }
        if driver == .webdriverAgent {
            let viewport = try await prepareWDAConnection(checkServer: false)
            try await wdaClient.tapBurst(taps, viewport: viewport, baseURL: wdaBaseURL, sessionID: wdaSessionID)
            markWDAReady(viewport: viewport)
        } else {
            for tap in taps { try await executeTap(tap.point, holdMilliseconds: tap.holdMilliseconds) }
        }
        if let last = taps.last { lastGesture = TouchFeedback(start: last.point, end: nil) }
    }

    /// A swipe from an automation, shifted and timed a little differently
    /// each time (`HumanTouch`); `exact` for swipes made by hand.
    func drag(from start: NormalizedPoint, to end: NormalizedPoint, duration: Double,
                  releaseHold: Double = 0, exact: Bool = false) async throws {
        var swipe = HumanTouch.Swipe(start: start, end: end, duration: duration, releaseHold: releaseHold)
        if !exact {
            var random = SystemRandomNumberGenerator()
            swipe = HumanTouch.swipe(from: start, to: end, duration: duration, releaseHold: releaseHold,
                                     screen: wdaViewport, using: &random)
            try await Task.sleep(nanoseconds: UInt64(HumanTouch.reaction(using: &random) * 1_000_000_000))
        }
        guard receiver.state == .playing, driver != .preview, controlPhase == .ready else {
            throw NSError(domain: AppBrand.current.name, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "AirPlay or iPhone touch control disconnected"])
        }
        try await executeDrag(from: swipe.start, to: swipe.end, duration: swipe.duration,
                              releaseHold: swipe.releaseHold)
        lastGesture = TouchFeedback(start: swipe.start, end: swipe.end)
    }


    /// Keys typed on the Mac, for whichever text field is focused on the
    /// iPhone. They arrive like a hardware keyboard's, so the iPhone's own
    /// keyboard isn't needed.
    func typeText(_ text: String) async throws {
        guard !AppData.isDemoProcess, receiver.state == .playing, driver != .preview,
              controlPhase == .ready else {
            throw NSError(domain: AppBrand.current.name, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                            "AirPlay or iPhone touch control disconnected", comment: "Mac keyboard")])
        }
        guard driver == .webdriverAgent else {
            throw NSError(domain: AppBrand.current.name, code: 6,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                            "Typing from the Mac needs WebDriverAgent touch control", comment: "Mac keyboard")])
        }
        for attempt in 0..<2 {
            let viewport = try await prepareWDAConnection(checkServer: false)
            do {
                try await wdaClient.typeText(text, baseURL: wdaBaseURL, sessionID: wdaSessionID)
                markWDAReady(viewport: viewport)
                return
            } catch WebDriverAgentError.server(let statusCode, _) where statusCode == 404 && attempt == 0 {
                // The runner restarted and dropped the session; make a new one once.
                invalidateWDASession()
            }
        }
    }

    /// Opens an installed iPhone app by its bundle ID, e.g. "com.apple.AppStore".
    func openApp(_ bundleIdentifier: String) async throws {
        try requireTouchControl()
        let viewport = try await prepareWDAConnection(checkServer: false)
        try await wdaClient.activateApp(bundleIdentifier, baseURL: wdaBaseURL, sessionID: wdaSessionID)
        markWDAReady(viewport: viewport)
    }

    /// Back to the iPhone's Home Screen.
    func goHome() async throws {
        try requireTouchControl()
        try await wdaClient.pressHome(baseURL: wdaBaseURL)
    }

    /// The text on the iPhone's screen right now, top to bottom.
    func readScreen(languages: [String] = ["en-US", "de-DE"]) async throws -> [ScreenText] {
        guard let frame = receiver.currentPixelBuffer() else {
            throw NSError(domain: AppBrand.current.name, code: 3,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("No picture from the iPhone yet", comment: "Read screen")])
        }
        let texts = try await Task.detached(priority: .userInitiated) {
            try VisionTextRecognizer.shared.recognize(frame, languages: languages, minimumTextHeight: 0.008,
                                                      minimumConfidence: 0.3)
        }.value
        return texts.sorted {
            let first = Int($0.rect.midY * 80), second = Int($1.rect.midY * 80)
            return first != second ? first < second : $0.rect.minX < $1.rect.minX
        }
    }

    private func requireTouchControl() throws {
        guard receiver.state == .playing, driver != .preview, controlPhase == .ready else {
            throw NSError(domain: AppBrand.current.name, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                            "AirPlay or iPhone touch control disconnected", comment: "Touch")])
        }
    }

    func foregroundBundleIdentifier() async throws -> String {
        guard activeControlTransport == .webdriverAgent else {
            throw WebDriverAgentError.missingSession
        }
        // This call deliberately does not use prepareWDAConnection: creating
        // a new session could reopen the app after the user left it.
        return try await wdaClient.activeAppBundleIdentifier(
            baseURL: wdaBaseURL,
            sessionID: wdaSessionID
        )
    }


    func reconnectControl() {
        guard !AppData.isDemoProcess else { return }
        invalidateWDASession()
        restartControlSupervisor()
        startWDARunnerIfNeeded()
    }

    func disconnectAirPlay() {
        guard receiver.state == .playing else { return }
        tools.mirrorWillDisconnect()
        receiver.restartReceiver()
    }

    func closeWindow() {
        recorder.windowWillClose()
        tools.windowWillClose()
        controlSupervisorTask?.cancel()
        cancelAirPlayDeviceIdentity()
        receiver.stopReceiver()
    }

    private func cancelAirPlayDeviceIdentity() {
        airPlayDeviceIdentityID = UUID()
        airPlayDeviceIdentityTask?.cancel()
        airPlayDeviceIdentityTask = nil
        isIdentifyingAirPlayIPhone = false
    }

    private func identifyAirPlayIPhone(host: String, phones: [PairedIPhone]? = nil) {
        cancelAirPlayDeviceIdentity()
        guard receiver.state == .playing, preferredDeviceUDID.isEmpty else { return }
        isIdentifyingAirPlayIPhone = true
        let identityID = UUID()
        airPlayDeviceIdentityID = identityID
        airPlayDeviceIdentityTask = Task { [weak self] in
            guard let self else { return }
            let candidates: [PairedIPhone]
            if let phones {
                candidates = phones
            } else {
                candidates = (try? await self.deviceDiscovery.discoverIPhones()) ?? []
            }
            guard !Task.isCancelled, self.airPlayDeviceIdentityID == identityID,
                  self.receiver.state == .playing,
                  self.receiver.senderHost == host else { return }
            self.discoveredIPhones = candidates
            // Connected from the iPhone list: no guessing which one it is.
            if let chosen = self.pendingMirrorDevice,
               let phone = candidates.first(where: { $0.hardwareUDID == chosen }) {
                self.pendingMirrorDevice = nil
                self.selectMatchedPhone(phone, source: .manual, host: host)
                return
            }
            let available = candidates.filter {
                $0.isBooted && !self.devicesUsedByOtherWindows.contains($0.hardwareUDID)
            }
            for attempt in 0..<3 {
                let bonjourName = await Task.detached(priority: .utility) {
                    AirPlayDeviceIdentity.reverseDNSName(for: host)
                }.value
                guard !Task.isCancelled, self.airPlayDeviceIdentityID == identityID else { return }
                if let matched = AirPlayDeviceIdentity.matchedIPhone(
                    forBonjourName: bonjourName, in: candidates
                ) {
                    self.selectMatchedPhone(matched, source: .bonjour, host: host)
                    return
                }
                // The Bonjour name often does not resolve. The phone that
                // used this AirPlay address last time is the next best
                // evidence; touches still go to the mirrored address only.
                if attempt == 0, let remembered = self.rememberedDevice(forAirPlayHost: host),
                   let phone = available.first(where: { $0.hardwareUDID == remembered }) {
                    self.selectMatchedPhone(phone, source: .remembered, host: host)
                    return
                }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            guard !Task.isCancelled, self.airPlayDeviceIdentityID == identityID else { return }
            if available.count == 1 {
                self.selectMatchedPhone(available[0], source: .onlyPhone, host: host)
                return
            }
            self.isIdentifyingAirPlayIPhone = false
            self.airPlayDeviceIdentityTask = nil
            self.wdaRunnerIssue = "Could not identify the mirrored iPhone in Xcode. Pair it or choose it manually."
        }
    }

    private func selectMatchedPhone(_ phone: PairedIPhone, source: DeviceMatchSource, host: String) {
        isIdentifyingAirPlayIPhone = false
        airPlayDeviceIdentityTask = nil
        didAutoMatchAirPlayIPhone = true
        deviceMatchSource = source
        rememberDevice(phone.hardwareUDID, forAirPlayHost: host)
        preferredDeviceUDID = phone.hardwareUDID
    }

    /// Something runs in this window: one of the app's tools, or a recording
    /// that plays.
    var isBusy: Bool { tools.isBusy || recorder.isPlaying }


    /// The picture stopped, or the same or another iPhone took over this
    /// window. WebDriverAgent keeps running on its iPhone either way: a new
    /// start makes iOS ask for the passcode, a running one is reused (also
    /// after the app restarts). Another iPhone gets a runner of its own.
    private func releaseAirPlayControl(switchingTo udid: String? = nil) {
        guard !AppData.isDemoProcess else { return }
        wdaStartupTask?.cancel()
        wdaStartupTask = nil
        if let udid, !udid.isEmpty, let running = wdaRunnerManager.runnerUDID, running != udid {
            wdaRunnerManager.detach()
        }
    }

    private func invalidateWDASession() {
        wdaSessionGeneration = UUID()
        wdaSessionCreationTask?.cancel()
        wdaSessionCreationTask = nil
        wdaSessionID = ""
        wdaViewport = nil
    }

    private func applyAirPlayWDAAddress(_ host: String) {
        guard useAirPlayWDAAddress,
              let detectedURL = AirPlayWDAEndpoint.directURL(
                for: host, scopeID: receiver.senderScopeID) else { return }
        AppData.preferences.set(detectedURL, forKey: lastTouchURLKey)
        if wdaBaseURL != detectedURL {
            wdaBaseURL = detectedURL
            if driver == .webdriverAgent { reconnectControl() }
        } else if driver == .webdriverAgent, controlPhase != .ready {
            // A fresh AirPlay connection should retry immediately instead of
            // waiting for the previous endpoint's retry countdown.
            reconnectControl()
        }
    }

    private func startWDARunnerIfNeeded() {
        guard !AppData.isDemoProcess, driver == .webdriverAgent, wdaStartupTask == nil,
              !preferredDeviceUDID.isEmpty,
              receiver.state == .playing,
              let host = receiver.senderHost,
              AirPlayWDAEndpoint.directURL(
                for: host, scopeID: receiver.senderScopeID) == wdaBaseURL else { return }
        wdaRunnerIssue = nil
        isStartingWDARunner = true
        wdaRunnerProgress = "Checking WebDriverAgent on this iPhone…"
        let endpoint = wdaBaseURL
        let startupID = UUID()
        wdaStartupID = startupID
        wdaStartupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.wdaStartupID == startupID {
                    self.isStartingWDARunner = false
                    self.wdaStartupTask = nil
                }
            }
            await self.wdaReleaseTask?.value
            guard !Task.isCancelled, self.receiver.state == .playing else { return }
            // A runner launched by Xcode outside this app is equally valid.
            if (try? await self.wdaClient.checkStatus(baseURL: endpoint)) != nil {
                self.retryWDASupervisorIfNeeded()
                return
            }
            do {
                try Task.checkCancellation()
                try await self.wdaRunnerManager.launchIfNeeded(
                    preferredUDID: self.preferredDeviceUDID,
                    progress: { [weak self] message in self?.wdaRunnerProgress = message })
                for _ in 0..<30 {
                    try Task.checkCancellation()
                    if (try? await self.wdaClient.checkStatus(baseURL: endpoint)) != nil {
                        self.retryWDASupervisorIfNeeded()
                        return
                    }
                    if let exit = self.wdaRunnerManager.exitDescription() {
                        self.wdaRunnerIssue = exit
                        return
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
                self.wdaRunnerIssue = "WebDriverAgent did not respond. Unlock the iPhone and check its XCTest prompt."
            } catch is CancellationError {
                return
            } catch {
                self.wdaRunnerIssue = error.localizedDescription
            }
        }
    }

    private func retryWDASupervisorIfNeeded() {
        // The supervisor may already be creating a session. Resetting it here
        // used to race a second /session request and relaunch the app twice.
        if controlPhase == .retrying || controlPhase == .unavailable || controlPhase == .error {
            restartControlSupervisor()
        }
    }

    /// On quit WebDriverAgent keeps running, so the next launch (an update)
    /// reuses it without the iPhone asking for its passcode.
    func stopManagedWDARunner() {
        wdaStartupTask?.cancel()
        wdaStartupTask = nil
        wdaReleaseTask?.cancel()
        wdaReleaseTask = nil
        wdaRunnerManager.detach()
    }

    // MARK: - Mirroring started from the Mac

    private var lastTouchURLKey: String { AppBrand.key("lastTouchURL.\(receiver.receiverName)") }
    private var lastTouchDeviceKey: String { AppBrand.key("lastTouchDevice.\(receiver.receiverName)") }
    private var mirroredAtKey: String { AppBrand.key("mirroredAt.\(receiver.receiverName)") }

    /// A ready touch-control address while nothing is mirrored: the runner
    /// still running from before, or a new one started over Wi-Fi on the
    /// iPhone this window used last.
    func touchEndpointWithoutAirPlay(progress: @escaping @MainActor (String) -> Void) async throws -> String {
        await wdaReleaseTask?.value
        let defaults = AppData.preferences
        func readyURL() async -> String? {
            var seen = Set<String>()
            let urls = [defaults.string(forKey: lastTouchURLKey), wdaBaseURL, wdaRunnerManager.announcedServerURL()]
                .compactMap { $0 }.filter { seen.insert($0).inserted }
            for url in urls where (try? await wdaClient.checkStatus(baseURL: url)) != nil { return url }
            return nil
        }
        if let url = await readyURL() { return url }
        progress(NSLocalizedString("Starting touch control on the iPhone…", comment: "Mirror connect status"))
        let report: @MainActor (String) -> Void = { message in progress(NSLocalizedString(message, comment: "WDA progress")) }
        do {
            try await wdaRunnerManager.launchIfNeeded(preferredUDID: defaults.string(forKey: lastTouchDeviceKey),
                                                      progress: report)
        } catch WebDriverAgentRunnerError.selectedIPhoneUnavailable {
            try await wdaRunnerManager.launchIfNeeded(preferredUDID: nil, progress: report)
        }
        for _ in 0..<45 {
            try Task.checkCancellation()
            if let url = await readyURL() { return url }
            if let exit = wdaRunnerManager.exitDescription() { throw WebDriverAgentRunnerError.commandFailed(exit) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw PhoneMirrorError.touchUnavailable
    }

    /// The iPhone "Connect" was pressed for; once its picture arrives this
    /// window uses it without guessing.
    private(set) var pendingMirrorDevice: String?

    func expectMirror(from udid: String?) { pendingMirrorDevice = udid }

    private static func deviceTouchURLKey(_ udid: String) -> String { AppBrand.key("touchURL.\(udid)") }

    /// The window's last iPhone, listed first.
    var lastConnectedDevice: String? { AppData.preferences.string(forKey: lastTouchDeviceKey) }

    /// Touch control on one chosen iPhone while nothing is mirrored: its
    /// runner if one still runs, else a new one on that iPhone.
    func touchEndpoint(for phone: PairedIPhone, progress: @escaping @MainActor (String) -> Void) async throws -> String {
        await wdaReleaseTask?.value
        let defaults = AppData.preferences
        let udid = phone.hardwareUDID
        let ownRunner = wdaRunnerManager
        func readyURL() async -> String? {
            var candidates = [defaults.string(forKey: Self.deviceTouchURLKey(udid)),
                              WebDriverAgentRunnerManager.announcedServerURL(forDevice: udid)]
            if defaults.string(forKey: lastTouchDeviceKey) == udid {
                candidates.append(defaults.string(forKey: lastTouchURLKey))
            }
            if ownRunner.runnerUDID == udid { candidates.append(ownRunner.announcedServerURL()) }
            var seen = Set<String>()
            for url in candidates.compactMap({ $0 }) where seen.insert(url).inserted {
                guard (try? await wdaClient.checkStatus(baseURL: url)) != nil else { continue }
                // An address can move to another iPhone. iOS mostly says
                // only "iPhone"; a real name has to match.
                if let name = try? await wdaClient.deviceName(baseURL: url),
                   name != "iPhone", name.caseInsensitiveCompare(phone.name) != .orderedSame { continue }
                return url
            }
            return nil
        }
        func remember(_ url: String) -> String {
            defaults.set(url, forKey: Self.deviceTouchURLKey(udid))
            defaults.set(url, forKey: lastTouchURLKey)
            defaults.set(udid, forKey: lastTouchDeviceKey)
            return url
        }
        if let url = await readyURL() { return remember(url) }
        progress(String(format: NSLocalizedString("Starting touch control on %@…", comment: "Mirror connect status"), phone.name))
        if let running = wdaRunnerManager.runnerUDID, running != udid { wdaRunnerManager.detach() }
        let report: @MainActor (String) -> Void = { message in progress(NSLocalizedString(message, comment: "WDA progress")) }
        try await wdaRunnerManager.launchIfNeeded(preferredUDID: udid, progress: report)
        for _ in 0..<45 {
            try Task.checkCancellation()
            if let url = await readyURL() { return remember(url) }
            if let exit = wdaRunnerManager.exitDescription() { throw WebDriverAgentRunnerError.commandFailed(exit) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw PhoneMirrorError.touchUnavailable
    }

    /// While mirroring, note the time now and then. A note that is still
    /// there at launch means the app ended while the iPhone was mirroring
    /// (an update or a crash), not that the iPhone stopped.
    private func startMirrorHeartbeat() {
        mirrorHeartbeatTask?.cancel()
        let key = mirroredAtKey
        mirrorHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled, self?.receiver.state == .playing {
                AppData.preferences.set(Date().timeIntervalSince1970, forKey: key)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func stopMirrorHeartbeat() {
        mirrorHeartbeatTask?.cancel()
        mirrorHeartbeatTask = nil
        guard !Self.isTerminating else { return }
        AppData.preferences.removeObject(forKey: mirroredAtKey)
    }

    func prepareForQuit() {
        Self.isTerminating = true
        if receiver.state == .playing {
            AppData.preferences.set(Date().timeIntervalSince1970, forKey: mirroredAtKey)
        }
    }

    /// Other AirPlay names whose iPhone was mirroring until the app ended a
    /// few minutes ago: their windows should open again after a relaunch.
    var otherRecentlyMirroredReceivers: [String] {
        let prefix = AppBrand.key("mirroredAt.")
        let now = Date().timeIntervalSince1970
        return AppData.preferences.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix(prefix), let time = value as? Double, now - time < 15 * 60 else { return nil }
            let name = String(key.dropFirst(prefix.count))
            return name == receiver.receiverName ? nil : name
        }
    }

    /// After an update or restart, mirror the iPhone again by itself when it
    /// was mirroring to this window a few minutes ago.
    private func reconnectAfterRelaunch() {
        let mirroredAt = AppData.preferences.double(forKey: mirroredAtKey)
        guard mirroredAt > 0, Date().timeIntervalSince1970 - mirroredAt < 15 * 60 else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            // Give the iPhone a moment to come back on its own.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.receiver.state != .playing else { return }
            await self.phoneConnector.connect(model: self, automatic: true)
        }
    }

    /// A run that waits for the picture pauses when it drops (Wi-Fi, a
    /// restart of the iPhone's mirroring). Mirror again from here, up to
    /// three times.
    private func reconnectForWaitingRun(attempt: Int = 1) {
        guard !Self.isTerminating, attempt <= 3, tools.waitsForMirror else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(attempt == 1 ? 15 : 60) * 1_000_000_000)
            guard let self, !Task.isCancelled, self.receiver.state != .playing,
                  self.tools.waitsForMirror else { return }
            if !(await self.phoneConnector.connect(model: self, automatic: true)) {
                self.reconnectForWaitingRun(attempt: attempt + 1)
            }
        }
    }

    private func executeTap(_ point: NormalizedPoint,
                            holdMilliseconds: Int = AppModel.tapHoldMilliseconds) async throws {
        switch driver {
        case .preview:
            try await Task.sleep(nanoseconds: 90_000_000)
        case .webdriverAgent:
            try await executeWDATap(point, holdMilliseconds: holdMilliseconds)
        }
    }

    private func executeDrag(
        from startPoint: NormalizedPoint,
        to endPoint: NormalizedPoint,
        duration: Double,
        releaseHold: Double = 0
    ) async throws {
        switch driver {
        case .preview:
            try await Task.sleep(
                nanoseconds: UInt64(min(max(duration, 0.10), 10) * 1_000_000_000)
            )
        case .webdriverAgent:
            try await executeWDADrag(from: startPoint, to: endPoint, duration: duration,
                                     releaseHold: releaseHold)
        }
    }

    private func executeWDATap(_ point: NormalizedPoint,
                               holdMilliseconds: Int = AppModel.tapHoldMilliseconds) async throws {
        let viewport = try await prepareWDAConnection(checkServer: false)
        try await wdaClient.tap(
            normalizedPoint: point,
            holdMilliseconds: holdMilliseconds,
            viewport: viewport,
            baseURL: wdaBaseURL,
            sessionID: wdaSessionID
        )
        markWDAReady(viewport: viewport)
    }

    private func executeWDADrag(
        from startPoint: NormalizedPoint,
        to endPoint: NormalizedPoint,
        duration: Double,
        releaseHold: Double = 0
    ) async throws {
        let viewport = try await prepareWDAConnection(checkServer: false)
        try await wdaClient.drag(
            from: startPoint,
            to: endPoint,
            duration: duration,
            releaseHold: releaseHold,
            viewport: viewport,
            baseURL: wdaBaseURL,
            sessionID: wdaSessionID
        )
        markWDAReady(viewport: viewport)
    }

    private func resolveActiveIPhone() async throws -> PairedIPhone {
        if let activeIPhone { return activeIPhone }

        let devices = try await deviceDiscovery.discoverIPhones()
        discoveredIPhones = devices
        guard let device = selectedDevice(from: devices) else {
            throw ControlError.noPairedIPhone
        }
        activeIPhone = device
        return device
    }

    private func prepareWDAConnection(checkServer: Bool) async throws -> CGSize {
        if checkServer {
            try await wdaClient.checkStatus(baseURL: wdaBaseURL)
            if !wdaSessionID.isEmpty {
                do {
                    _ = try await wdaClient.activeAppBundleIdentifier(baseURL: wdaBaseURL,
                                                                       sessionID: wdaSessionID)
                } catch WebDriverAgentError.server(let statusCode, _) where statusCode == 404 {
                    invalidateWDASession()
                }
            }
        }

        if !wdaSessionID.isEmpty {
            if let wdaViewport { return wdaViewport }
            if let viewport = try? await wdaClient.viewportSize(
                baseURL: wdaBaseURL,
                sessionID: wdaSessionID
            ) {
                wdaViewport = viewport
                return viewport
            }
            // A restarted runner invalidates its old session. Recreate it
            // rather than silently falling back to unauthorized direct taps.
            wdaSessionID = ""
            wdaViewport = nil
        }

        // Creating an XCTest session with a bundle ID can bring the app to
        // the front. The app's tools say when that would happen behind the
        // user's back (they switched to another iPhone app mid-run).
        guard tools.allowsSessionCreation else {
            throw WebDriverAgentError.missingSession
        }

        let generation = wdaSessionGeneration
        let createdID: String
        if let existingTask = wdaSessionCreationTask {
            createdID = try await existingTask.value
        } else {
            let client = wdaClient
            let endpoint = wdaBaseURL
            let bundleIdentifier = wdaBundleIdentifier
            let task = Task {
                try await client.createSession(baseURL: endpoint, bundleIdentifier: bundleIdentifier)
            }
            wdaSessionCreationTask = task
            defer {
                if generation == wdaSessionGeneration { wdaSessionCreationTask = nil }
            }
            createdID = try await task.value
        }
        guard generation == wdaSessionGeneration else { throw CancellationError() }
        wdaSessionID = createdID

        do {
            let viewport = try await wdaClient.viewportSize(
                baseURL: wdaBaseURL,
                sessionID: wdaSessionID
            )
            wdaViewport = viewport
            return viewport
        } catch {
            // Keep a real XCTest session even when this iOS build declines
            // its window-size endpoint. Apple's paired-device display metadata
            // still supplies the logical viewport for normalized AirPlay taps.
            if let device = try? await resolveActiveIPhone(),
               let viewport = try? await deviceDiscovery.logicalDisplaySize(for: device.hardwareUDID) {
                wdaViewport = viewport
                return viewport
            }
            throw error
        }
    }

    private func restartControlSupervisor() {
        // Interface demos must never reach a real iPhone or its runner.
        guard !AppData.isDemoProcess else { return }
        controlSupervisorTask?.cancel()
        let supervisorID = UUID()
        controlSupervisorID = supervisorID
        activeControlTransport = nil
        controlRetryCount = 0

        if driver == .preview {
            controlPhase = .preview
            controlDetail = "Gestures are recorded without controlling a device."
            return
        }

        controlPhase = .searching
        controlDetail = driver == .webdriverAgent
            ? "Checking WebDriverAgent…"
            : "Finding a paired iPhone…"

        controlSupervisorTask = Task { [weak self] in
            guard let self else { return }
            switch driver {
            case .webdriverAgent:
                await superviseWDA(id: supervisorID)
            case .preview:
                return
            }
        }
    }

    private func superviseWDA(id: UUID) async {
        var failures = 0

        while !Task.isCancelled, controlSupervisorID == id {
            guard receiver.state == .playing else {
                controlPhase = .searching
                controlDetail = "Waiting for iPhone AirPlay…"
                try? await Task.sleep(nanoseconds: 800_000_000)
                continue
            }
            guard !preferredDeviceUDID.isEmpty else {
                controlPhase = .searching
                controlDetail = isIdentifyingAirPlayIPhone
                    ? "Identifying the mirrored iPhone…"
                    : "Pair the mirrored iPhone in Xcode or choose it manually."
                try? await Task.sleep(nanoseconds: 800_000_000)
                continue
            }
            do {
                if controlPhase != .ready {
                    controlPhase = .connecting
                    controlDetail = "Checking WebDriverAgent…"
                }
                let viewport = try await prepareWDAConnection(checkServer: true)
                guard !Task.isCancelled, controlSupervisorID == id else { return }
                failures = 0
                controlRetryCount = 0
                markWDAReady(viewport: viewport)
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch is CancellationError {
                return
            } catch {
                guard controlSupervisorID == id else { return }
                failures += 1
                controlRetryCount = failures
                activeControlTransport = nil
                let delay = DeviceControlRetryPolicy.delaySeconds(afterFailure: failures)
                controlPhase = .retrying
                controlDetail = "\(conciseControlError(error)) · retrying in \(delay)s"
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
    }

    private func selectedDevice(from devices: [PairedIPhone]) -> PairedIPhone? {
        if !preferredDeviceUDID.isEmpty,
           let preferred = devices.first(where: { $0.hardwareUDID == preferredDeviceUDID }) {
            return preferred
        }
        return nil
    }

    private func markWDAReady(viewport: CGSize) {
        wdaViewport = viewport
        activeControlTransport = .webdriverAgent
        controlPhase = .ready
        controlDetail = "WebDriverAgent · \(Int(viewport.width))×\(Int(viewport.height)) pt"
        controlRetryCount = 0
    }

    private func noteControlFailure(_ error: Error) {
        guard driver != .preview else { return }
        activeControlTransport = nil
        controlPhase = isUnlockError(error) ? .unlockRequired : .retrying
        controlDetail = conciseControlError(error)
        restartControlSupervisor()
    }

    private func isUnlockError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("unlock") || message.contains("locked")
    }

    private func conciseControlError(_ error: Error) -> String {
        let message = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isUnlockError(error) {
            return "Unlock the iPhone and leave it awake"
        }
        if message.localizedCaseInsensitiveContains("timed out"),
           let endpoint = URLComponents(string: wdaBaseURL),
           let host = endpoint.host {
            return "No response from WebDriverAgent at \(host):\(endpoint.port ?? 8100)"
        }
        if message.localizedCaseInsensitiveContains("connection refused")
            || message.localizedCaseInsensitiveContains("couldn’t connect")
            || message.localizedCaseInsensitiveContains("could not connect") {
            return driver == .webdriverAgent ? "WebDriverAgent is not running" : "iPhone control is unavailable"
        }
        return message.isEmpty ? "iPhone control is unavailable" : message
    }

}
