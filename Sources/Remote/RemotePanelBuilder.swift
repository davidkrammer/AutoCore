import AppKit
import Foundation

/// Builds what the Remote shows for one window: the same settings, numbers
/// and buttons as the Mac panels, read from and written to the same places.
/// Each control and button registers what it does, so a change from the
/// iPhone runs exactly the code a click on the Mac runs. Apps add their tabs'
/// pages in `WindowTools.remotePanel(for:builder:)` with the helpers below.
@MainActor
final class RemotePanelBuilder {
    let model: AppModel
    /// Values the Remote keeps for itself, not Mac settings (e.g. a search).
    let local: [String: String]
    /// What the Remote's controls and buttons do, by id.
    var setters: [String: (RemoteValue) -> Void] = [:]
    var actions: [String: () -> Void] = [:]
    /// Ids of controls whose value the Remote keeps (`local`).
    var localKeys: Set<String> = []
    let defaults = AppData.preferences
    var window: String { model.receiver.receiverName }

    init(model: AppModel, local: [String: String] = [:]) {
        self.model = model
        self.local = local
    }

    // MARK: - Window summary

    static func summary(_ model: AppModel) -> RemoteWindow {
        let receiver = model.receiver
        let link: String
        switch model.linkHealth {
        case .ready: link = "ready"
        case .working: link = "working"
        case .off: link = "off"
        case .problem: link = "problem"
        }
        let size = receiver.videoSize
        return RemoteWindow(
            id: model.windowID, name: receiver.receiverName,
            account: model.accountName.map { AppBrand.current.accountPrefix + $0 },
            accountConfirmed: model.accountConfirmed,
            phone: model.activeIPhone?.name, link: link, linkSummary: model.linkSummary,
            mirroring: receiver.state == .playing && receiver.hasFrame,
            controlReady: model.controlPhase == .ready, busy: model.isBusy,
            lockedMode: model.lockedMode, selectedMode: model.selectedMode,
            aspect: receiver.hasFrame && size.height > 0 ? Double(size.width / size.height) : 1242.0 / 2688.0,
            activity: model.activityLine,
            modes: model.tools.modes.map {
                RemoteOption(id: $0.id, title: NSLocalizedString($0.title, comment: "Tab"), symbol: $0.symbol,
                             tint: $0.remoteTint)
            })
    }

    // MARK: - Pages

    /// The page of one of the app's tabs.
    func panel(for mode: String) -> RemotePanel {
        model.tools.remotePanel(for: mode, builder: self)
    }

    /// A value the Remote keeps for itself (`local`): a text field whose
    /// text is not a Mac setting.
    func localText(_ id: String, _ title: String, placeholder: String) -> RemoteControl {
        localKeys.insert(id)
        return RemoteControl(id, .text(title: title, value: local[id] ?? "", placeholder: placeholder))
    }

    // MARK: - iPhone page

    func setup() -> RemotePanel {
        let receiver = model.receiver
        let connector = model.phoneConnector
        var blocks: [RemoteBlock] = []
        if receiver.state == .playing {
            let linkState = model.linkHealth == .ready ? NSLocalizedString("Touch control ready", comment: "Remote")
                : NSLocalizedString(model.controlStatusTitle, comment: "Touch connection status")
            var rows = [RemoteRow(id: "phone", title: model.activeIPhone?.name ?? NSLocalizedString("Identifying the iPhone…", comment: "Remote"),
                                  detail: (model.activeIPhone?.modelName).flatMap { $0.isEmpty ? nil : $0 + " · " + linkState } ?? linkState,
                                  symbol: "iphone",
                                  tint: model.linkHealth == .ready ? "success" : model.linkHealth == .problem ? "danger" : "warning")]
            if model.linkHealth == .problem || model.controlPhase == .retrying {
                rows.append(RemoteRow(id: "control", title: NSLocalizedString(model.controlStatusTitle, comment: "Touch connection status"),
                                      detail: model.controlStatusDetail, symbol: "hand.tap", tint: "warning"))
            }
            blocks.append(RemoteBlock("link", .rows(RemoteRows(title: receiver.receiverName, rows: rows))))
            var linkActions: [RemoteAction] = []
            if model.linkHealth == .problem || model.controlPhase == .retrying {
                linkActions.append(action("setup.retry", NSLocalizedString("Retry touch control", comment: "Button"),
                                          symbol: "arrow.clockwise", enabled: !model.isBusy) { [weak self] in
                    self?.model.reconnectControl()
                })
            }
            linkActions.append(action("setup.disconnect", NSLocalizedString("Disconnect iPhone", comment: "Button"), symbol: "power",
                                      style: .destructive,
                                      confirm: NSLocalizedString("Stops the AirPlay picture. Touch control keeps running on the iPhone, so connecting again needs no passcode.", comment: "Disconnect help")) { [weak self] in
                self?.model.disconnectAirPlay()
            })
            blocks.append(RemoteBlock("linkActions", .actions(linkActions)))
        } else {
            let last = model.lastConnectedDevice
            let used = model.devicesUsedByOtherWindows
            let phones = model.discoveredIPhones.sorted { a, b in
                if (a.hardwareUDID == last) != (b.hardwareUDID == last) { return a.hardwareUDID == last }
                if a.isBooted != b.isBooted { return a.isBooted }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            let rows = phones.map { phone -> RemoteRow in
                let id = "setup.connect." + phone.hardwareUDID
                let usedBy = WindowRegistry.shared.models.first { $0 !== model && $0.preferredDeviceUDID == phone.hardwareUDID }
                let available = phone.isBooted && !used.contains(phone.hardwareUDID) && !connector.isWorking && !model.isBusy
                if available {
                    actions[id] = { [weak self] in
                        guard let self else { return }
                        Task { await self.model.phoneConnector.connect(model: self.model, phone: phone) }
                    }
                }
                var detail = [phone.modelName, phone.osVersion.isEmpty ? "" : "iOS " + phone.osVersion].filter { !$0.isEmpty }
                if phone.hardwareUDID == last { detail.append(NSLocalizedString("used last", comment: "Phone chooser")) }
                if let usedBy { detail = [String(format: NSLocalizedString("In use by %@", comment: "Phone chooser"), usedBy.receiver.receiverName)] }
                if !phone.isBooted { detail = [NSLocalizedString("Not reachable", comment: "Phone chooser")] }
                return RemoteRow(id: phone.hardwareUDID, title: phone.name, detail: detail.joined(separator: " · "),
                                 trailing: connector.connectingDevice == phone.hardwareUDID ? "…"
                                    : available ? NSLocalizedString("Connect", comment: "Button") : nil,
                                 symbol: "iphone", tint: available ? "accent" : "secondary",
                                 action: available ? id : nil, enabled: available)
            }
            blocks.append(RemoteBlock("phones", .rows(RemoteRows(
                title: String(format: NSLocalizedString("Connect an iPhone to %@", comment: "Remote"), receiver.receiverName),
                rows: rows, empty: NSLocalizedString("No paired iPhone found. Pair one in Xcode › Device Hub on the Mac.", comment: "Remote"),
                footer: String(format: NSLocalizedString("%@ starts touch control and Screen Mirroring on the iPhone you choose; it has to be unlocked. Or on that iPhone: Control Center › Screen Mirroring › %@.", comment: "Remote"),
                               AppBrand.current.name, receiver.receiverName)))))
            switch connector.phase {
            case let .working(message):
                blocks.append(RemoteBlock("connecting", .notice(RemoteNotice(text: message, symbol: "iphone.radiowaves.left.and.right", tint: "warning"))))
            case let .failed(message):
                blocks.append(RemoteBlock("connecting", .notice(RemoteNotice(text: message, symbol: "exclamationmark.triangle.fill", tint: "warning"))))
            case .idle:
                break
            }
            blocks.append(RemoteBlock("refresh", .actions([action("setup.refresh", NSLocalizedString("Refresh iPhones", comment: "Button"),
                                                                  symbol: "arrow.clockwise") { [weak self] in
                guard let self else { return }
                Task { await self.model.refreshPairedIPhones() }
            }])))
        }
        blocks += model.tools.remoteSetup(builder: self)
        blocks += recorderBlocks()
        var more: [RemoteAction] = []
        if let open = openWindowAction() { more.append(open) }
        let repair = TextRecognitionRepair.shared
        if WindowRegistry.shared.windowCount >= 2, model.hostWindow != nil {
            more.append(action("setup.closeWindow",
                               String(format: NSLocalizedString("Close %@", comment: "Remote close window"), receiver.receiverName),
                               symbol: "xmark.rectangle", style: .destructive,
                               confirm: String(format: NSLocalizedString("Closes the %@ window on the Mac. Whatever runs there stops; touch control keeps running on its iPhone, so it connects again without a passcode.", comment: "Remote close window"),
                                               receiver.receiverName)) { [model] in
                model.hostWindow?.close()
            })
        }
        more.append(action("setup.rebuild", NSLocalizedString("Rebuild text recognition", comment: "Button"), symbol: "text.viewfinder",
                           subtitle: NSLocalizedString("When macOS deleted the text recognition files. Takes one to two minutes.", comment: "Rebuild menu help"),
                           enabled: !repair.isRebuilding && !model.isBusy) { repair.rebuild() })
        blocks.append(RemoteBlock("more", .actions(more)))
        return RemotePanel(title: model.accountName.map { AppBrand.current.accountPrefix + $0 } ?? receiver.receiverName,
                           subtitle: model.linkSummary, counter: nil, blocks: blocks)
    }

    /// Record & Play: start or end a recording, or play a saved one.
    private func recorderBlocks() -> [RemoteBlock] {
        let recorder = model.recorder
        let canStart = model.controlPhase == .ready && !model.isBusy
        switch recorder.state {
        case .recording:
            return [RemoteBlock("recorder", .status(RemoteStatus(
                pill: NSLocalizedString("RECORDING", comment: "Remote pill"), tint: "danger",
                title: String(format: NSLocalizedString("%d steps", comment: "Recorder"), recorder.draft?.steps.count ?? 0),
                detail: NSLocalizedString("Taps, swipes and typing on the Live tab are recorded too.", comment: "Remote"),
                symbol: "record.circle", since: recorder.draft?.startedAt,
                actions: [action("recorder.save", NSLocalizedString("Save", comment: "Button"), symbol: "stop.fill",
                                 style: .primary) { [recorder] in recorder.stopRecording() },
                          action("recorder.discard", NSLocalizedString("Discard", comment: "Button"), symbol: "trash",
                                 style: .destructive, tint: "danger",
                                 confirm: NSLocalizedString("The steps recorded so far are not saved.", comment: "Recorder")) {
                              [recorder] in recorder.stopRecording(save: false)
                          }])))]
        case .playing:
            return [RemoteBlock("recorder", .status(RemoteStatus(
                pill: NSLocalizedString("PLAYING", comment: "Remote pill"), tint: "accent",
                title: recorder.playing?.name ?? "", detail: recorder.activityLine, symbol: "play.circle.fill",
                actions: [stopAction("recorder.stop") { [recorder] in recorder.stopPlaying() }])))]
        case .idle:
            let options = PlaybackOptions.saved
            let rows = RecordingLibrary.shared.recordings.prefix(20).map { recording -> RemoteRow in
                let id = "recorder.play." + recording.id.uuidString
                if canStart { actions[id] = { [recorder] in recorder.play(recording, options: options) } }
                return RemoteRow(id: recording.id.uuidString, title: recording.name, detail: RecorderMenu.details(recording),
                                 trailing: NSLocalizedString("Play", comment: "Button"), symbol: "play.circle.fill",
                                 tint: "accent", action: canStart ? id : nil, enabled: canStart)
            }
            let times = options.repeats == 0 ? NSLocalizedString("until stopped", comment: "Recorder")
                : options.repeats == 1 ? NSLocalizedString("once", comment: "Recorder")
                : String(format: NSLocalizedString("%d times", comment: "Recorder"), options.repeats)
            return [RemoteBlock("record", .actions([
                        action("recorder.record", NSLocalizedString("Start recording", comment: "Button"),
                               symbol: "record.circle", tint: "danger", enabled: canStart) { [recorder] in
                            recorder.startRecording()
                        }])),
                    RemoteBlock("recordings", .rows(RemoteRows(
                        title: NSLocalizedString("Recordings", comment: "Section"), rows: Array(rows),
                        empty: NSLocalizedString("No recordings yet.", comment: "Recorder"),
                        footer: String(format: NSLocalizedString("Plays %@ at %@ speed, as set in Record & Play on the Mac.", comment: "Recorder"),
                                       times, options.speed == 0.5 ? "½×" : "\(Int(options.speed))×"))))]
        }
    }

    /// "Open a window for another iPhone", while only one is open.
    func openWindowAction() -> RemoteAction? {
        guard WindowRegistry.shared.windowCount < 2, RemoteWindowOpener.shared.canOpen else { return nil }
        return action("setup.openWindow", NSLocalizedString("Open a window for another iPhone", comment: "Button"),
                      symbol: "macwindow.badge.plus",
                      subtitle: NSLocalizedString("Each window controls its own iPhone, and both can run at once.", comment: "Second window help")) {
            RemoteWindowOpener.shared.open()
        }
    }

    // MARK: - Helpers for the app's pages

    func windowKey(_ base: String) -> String { WindowSetting.key(base, window: window) }

    /// A window setting as the Mac panel reads it (window value, else the
    /// old shared value, else the default).
    func windowValue<T>(_ base: String, _ fallback: T) -> T {
        defaults.object(forKey: windowKey(base)) as? T ?? defaults.object(forKey: base) as? T ?? fallback
    }

    func action(_ id: String, _ title: String, symbol: String? = nil, style: RemoteAction.Style = .secondary,
                tint: String? = nil, subtitle: String? = nil, enabled: Bool = true, confirm: String? = nil,
                perform: @escaping () -> Void) -> RemoteAction {
        if enabled { actions[id] = perform }
        return RemoteAction(id: id, title: title, symbol: symbol, style: style, tint: tint, subtitle: subtitle,
                            enabled: enabled, confirm: confirm)
    }

    func stopAction(_ id: String, perform: @escaping () -> Void) -> RemoteAction {
        action(id, NSLocalizedString("Stop", comment: "Button"), symbol: "stop.fill", style: .destructive, tint: "danger", perform: perform)
    }

    func toggle(_ id: String, _ title: String, value: Bool, set: @escaping (Bool) -> Void) -> RemoteControl {
        setters[id] = { if case let .bool(new) = $0 { set(new) } }
        return RemoteControl(id, .toggle(title: title, value: value))
    }

    func windowToggle(_ base: String, _ title: String, value: Bool) -> RemoteControl {
        toggle(base, title, value: value) { [defaults, key = windowKey(base)] in defaults.set($0, forKey: key) }
    }

    func choice(_ id: String, _ title: String?, _ options: [RemoteOption], value: String,
                        style: RemoteControl.ChoiceStyle = .segmented, set: @escaping (String) -> Void) -> RemoteControl {
        setters[id] = { new in
            guard case let .string(string) = new, options.contains(where: { $0.id == string }) else { return }
            set(string)
        }
        return RemoteControl(id, .choice(title: title, options: options, value: value, style: style))
    }

    func windowChoice(_ base: String, _ title: String?, _ options: [(String, String, String?)], value: String,
                              style: RemoteControl.ChoiceStyle = .segmented, tints: [String: String] = [:]) -> RemoteControl {
        choice(base, title, options.map { RemoteOption(id: $0.0, title: $0.1, symbol: $0.2, tint: tints[$0.0]) },
               value: value, style: options.count > 4 ? .menu : style) { [defaults, key = windowKey(base)] in
            defaults.set($0, forKey: key)
        }
    }

    func globalChoice(_ key: String, _ title: String?, _ options: [(String, String)], value: String) -> RemoteControl {
        choice(key, title, options.map { RemoteOption(id: $0.0, title: $0.1) }, value: value) { [defaults] in
            defaults.set($0, forKey: key)
        }
    }

    func windowIntChoice(_ base: String, _ title: String?, _ options: [(Int, String)], value: Int,
                                 style: RemoteControl.ChoiceStyle = .segmented) -> RemoteControl {
        choice(base, title, options.map { RemoteOption(id: "\($0.0)", title: $0.1) }, value: "\(value)",
               style: options.count > 4 ? .menu : style) { [defaults, key = windowKey(base)] in
            if let number = Int($0) { defaults.set(number, forKey: key) }
        }
    }

    func number(_ id: String, _ title: String, value: Int, range: ClosedRange<Int>, format: String?, zero: String?,
                        set: @escaping (Int) -> Void) -> RemoteControl {
        setters[id] = { new in
            guard case let .int(number) = new else { return }
            set(min(max(number, range.lowerBound), range.upperBound))
        }
        return RemoteControl(id, .number(title: title, value: value, minimum: range.lowerBound, maximum: range.upperBound,
                                         step: 1, format: format, zeroTitle: zero))
    }

    func windowNumber(_ base: String, _ title: String, value: Int, range: ClosedRange<Int>,
                              format: String? = nil, zero: String? = nil) -> RemoteControl {
        number(base, title, value: value, range: range, format: format, zero: zero) { [defaults, key = windowKey(base)] in
            defaults.set($0, forKey: key)
        }
    }

    func globalNumber(_ key: String, _ title: String, value: Int, range: ClosedRange<Int>, format: String?) -> RemoteControl {
        number(key, title, value: value, range: range, format: format, zero: nil) { [defaults] in defaults.set($0, forKey: key) }
    }

    func multi(_ id: String, _ title: String?, _ options: [RemoteOption], values: [String], minimum: Int,
                       set: @escaping ([String]) -> Void) -> RemoteControl {
        setters[id] = { new in
            guard case let .strings(list) = new else { return }
            let valid = list.filter { item in options.contains { $0.id == item } }
            guard valid.count >= minimum else { return }
            set(valid)
        }
        return RemoteControl(id, .multi(title: title, options: options, values: values, minimum: minimum))
    }

    func text(_ id: String, _ title: String, value: String, placeholder: String,
                      set: @escaping (String) -> Void) -> RemoteControl {
        setters[id] = { new in
            guard case let .string(string) = new, string.count <= 64 else { return }
            set(string)
        }
        return RemoteControl(id, .text(title: title, value: value, placeholder: placeholder))
    }
}

/// Opens a second window for the Remote; SwiftUI's openWindow is
/// only available inside a view, so the first window hands it over.
@MainActor
final class RemoteWindowOpener {
    static let shared = RemoteWindowOpener()
    var opener: (() -> Void)?
    var canOpen: Bool { opener != nil }
    func open() { opener?() }
}

extension AppModel {
    var selectedModeKey: String { WindowSetting.key(AppBrand.key("selectedMode"), window: receiver.receiverName) }

    /// The tab the Mac window shows: a running tool's, else the chosen one.
    var selectedMode: String {
        if let locked = lockedMode { return locked }
        let stored = AppData.preferences.string(forKey: selectedModeKey)
            ?? AppData.preferences.string(forKey: AppBrand.key("selectedMode"))
        return stored.flatMap { id in tools.modes.contains { $0.id == id } ? id : nil } ?? Tools.defaultMode
    }
}
