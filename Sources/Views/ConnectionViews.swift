import SwiftUI

/// What the account menu can open in the window around it.
struct AccountMenuActions {
    var openSecondWindow: (() -> Void)?
    var showRemote: () -> Void = {}
    var rebuildRecognition: (() -> Void)?
}

/// The iPhone link (AirPlay picture and touch control) as one state.
enum LinkHealth {
    case ready, working, off, problem

    var color: Color {
        switch self {
        case .ready: return Palette.success
        case .working: return Palette.warning
        case .off: return Color.secondary
        case .problem: return Palette.danger
        }
    }
}

extension AppModel {
    var linkHealth: LinkHealth {
        if receiver.state != .playing {
            return phoneConnector.isWorking || receiver.state == .connecting ? .working : .off
        }
        switch controlPhase {
        case .ready, .preview: return .ready
        case .unlockRequired, .unavailable, .error: return .problem
        case .searching, .connecting, .retrying: return .working
        }
    }

    /// One short line: "iPhone XS · Ready", "Not connected", "Unlock iPhone".
    var linkSummary: String {
        if receiver.state != .playing {
            if case let .working(message) = phoneConnector.phase { return message }
            return NSLocalizedString(receiver.state == .connecting ? "Connecting…" : "Not connected",
                                     comment: "Link summary")
        }
        let status = linkHealth == .ready
            ? NSLocalizedString("Ready", comment: "Link summary")
            : NSLocalizedString(controlStatusTitle, comment: "Touch connection status")
        guard let phone = activeIPhone?.name else { return status }
        return "\(phone) · \(status)"
    }
}

/// The title bar's only control: account, link state and every setting
/// behind one button.
struct AccountButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var receiver: DirectAirPlayReceiver
    @ObservedObject var connector: PhoneMirrorConnector
    var actions: AccountMenuActions
    /// Only the avatar, for a window without its panel.
    var compact = false
    @State private var showMenu = false

    var body: some View {
        Button { showMenu.toggle() } label: {
            HStack(spacing: 7) {
                AccountAvatar(model: model, size: 20)
                if !compact {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(model.accountConfirmed ? Color.primary : Color.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.leading, 3)
            .padding(.trailing, 7)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(model.linkSummary)
        .accessibilityLabel(Text("Account and iPhone"))
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            AccountMenu(model: model, receiver: receiver, connector: connector, actions: actions) {
                showMenu = false
            }
        }
        .task {
            // `--ui-demo menu…` opens it for screenshots.
            guard AppData.demoScenario?.hasPrefix("menu") == true else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showMenu = true
        }
    }

    private var title: String {
        if let name = model.accountName { return AppBrand.current.accountPrefix + name }
        if receiver.state == .playing, let detecting = AppBrand.current.detectingAccount { return detecting }
        return model.linkSummary
    }
}

/// The account's picture with a dot for the iPhone link.
struct AccountAvatar: View {
    @ObservedObject var model: AppModel
    var size: CGFloat
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let name = model.accountName {
                model.tools.accountBadge(name, size: size)
            } else {
                Image(systemName: "iphone")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            Circle()
                .fill(model.linkHealth.color)
                .frame(width: size * 0.42, height: size * 0.42)
                .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: max(1.5, size * 0.07)))
                .opacity(model.linkHealth == .working && pulse ? 0.35 : 1)
                .offset(x: size * 0.08, y: size * 0.08)
                .animation(model.linkHealth == .working
                           ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
                .onAppear { pulse = true }
        }
    }
}

/// Everything in one place: the iPhone link, the account and the rest.
struct AccountMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var receiver: DirectAirPlayReceiver
    @ObservedObject var connector: PhoneMirrorConnector
    let actions: AccountMenuActions
    let close: () -> Void
    @State private var showPairingHelp = false
    @State private var hubOpenFailed = false

    private var availablePhones: [PairedIPhone] { model.discoveredIPhones.filter(\.isBooted) }
    private var selectedPhone: PairedIPhone? {
        availablePhones.first { $0.hardwareUDID == model.preferredDeviceUDID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            link
            Divider()
            model.tools.accountSection(close: close)
            settings
        }
        .padding(14)
        .frame(width: 300)
        .task { await model.refreshPairedIPhones() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AccountAvatar(model: model, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.accountName.map { AppBrand.current.accountPrefix + $0 }
                     ?? AppBrand.current.noAccount ?? model.activeIPhone?.name ?? receiver.receiverName)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.linkSummary)
                    .font(.caption)
                    .foregroundStyle(model.linkHealth == .problem ? Palette.danger : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: iPhone link

    @ViewBuilder private var link: some View {
        if receiver.state != .playing {
            VStack(alignment: .leading, spacing: 6) {
                PhoneChooser(model: model, connector: connector, compact: true)
                Text(String(format: NSLocalizedString("Or on the iPhone: Control Center › Screen Mirroring › %@",
                                                      comment: "Account menu"), receiver.receiverName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            if model.isIdentifyingAirPlayIPhone {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Identifying the mirrored iPhone…").font(.caption)
                }
            } else if selectedPhone == nil || availablePhones.count > 1 {
                Picker("iPhone", selection: Binding(
                    get: { selectedPhone?.hardwareUDID ?? "" },
                    set: { model.selectIPhoneManually($0) }
                )) {
                    Text("Choose iPhone").tag("")
                    ForEach(availablePhones) { phone in Text(phone.name).tag(phone.hardwareUDID) }
                }
                .disabled(model.isBusy || availablePhones.isEmpty)
            }
            if model.linkHealth == .problem || model.controlPhase == .retrying {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.controlStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if selectedPhone != nil {
                        Button("Retry touch control") { model.reconnectControl() }
                            .disabled(model.isBusy)
                    }
                }
            }
        }
        if let issue = model.deviceDiscoveryIssue {
            Text(issue).font(.caption).foregroundStyle(Palette.warning)
        }
    }

    // MARK: Everything else

    private var settings: some View {
        VStack(alignment: .leading, spacing: 2) {
            model.tools.menuItems(close: close)
            item("Open a window for another iPhone", "macwindow.on.rectangle", then: actions.openSecondWindow)
                .help(NSLocalizedString("Each window controls its own iPhone, and both can run at once.",
                                        comment: "Second window help"))
            item("\(AppBrand.current.name) Remote…", "iphone.gen3.radiowaves.left.and.right", then: actions.showRemote)
                .help(String(format: NSLocalizedString("Control %@ from your iPhone", comment: "Remote menu help"),
                             AppBrand.current.name))
            MenuRow(action: { withAnimation(.easeOut(duration: 0.15)) { showPairingHelp.toggle() } }) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary).frame(width: 18)
                Text("Connect a new iPhone…")
                Spacer(minLength: 0)
                Image(systemName: showPairingHelp ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            if showPairingHelp { pairingHelp }
            if let support = AppBrand.current.supportURL {
                item("Support \(AppBrand.current.name)…", "heart", then: { NSWorkspace.shared.open(support) })
                    .help(NSLocalizedString("Free and open source; a donation keeps it going.", comment: "Support menu help"))
            }
            item("Rebuild text recognition", "text.viewfinder", then: actions.rebuildRecognition)
                .help(NSLocalizedString("Use this when macOS deleted the text recognition files. Takes one to two minutes.",
                                        comment: "Rebuild menu help"))
            if receiver.state == .playing {
                Divider().padding(.vertical, 4)
                MenuRow(action: {
                    close()
                    model.disconnectAirPlay()
                }) {
                    Image(systemName: "power").foregroundStyle(Palette.danger).frame(width: 18)
                    Text("Disconnect iPhone").foregroundStyle(Palette.danger)
                }
                .help(NSLocalizedString("Stops the AirPlay picture. Touch control keeps running on the iPhone, so connecting again needs no passcode.", comment: "Disconnect help"))
            }
        }
    }

    private var pairingHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pair it once in Xcode Device Hub, then choose it in this window.")
            Text("iOS 27 or newer: use Pair Nearby Device on the same Wi-Fi.")
            Text("Older iOS: connect the iPhone to this Mac with a cable.")
            Text("Unlock the iPhone, tap Trust, and enable Developer Mode if asked.")
            HStack {
                Button("Open Xcode Device Hub") { hubOpenFailed = !DeviceHubLauncher.open() }
                Spacer()
                Button {
                    Task { await model.refreshPairedIPhones() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Refresh paired iPhones", comment: "Refresh button"))
            }
            if hubOpenFailed {
                Text("Could not open Device Hub. Open Xcode → Xcode → Open Developer Tool → Device Hub.")
                    .foregroundStyle(Palette.warning)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 35)
        .padding(.vertical, 4)
    }

    private func item(_ title: LocalizedStringKey, _ symbol: String, then action: (() -> Void)?) -> some View {
        AccountMenuItem(title: title, symbol: symbol, close: close, action: action)
    }
}

/// A row of the account menu that closes the menu, then acts; dimmed when
/// `action` is nil.
struct AccountMenuItem: View {
    let title: LocalizedStringKey
    let symbol: String
    let close: () -> Void
    let action: (() -> Void)?

    var body: some View {
        MenuRow(action: {
            guard let action else { return }
            close()
            DispatchQueue.main.async(execute: action)
        }) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(title)
        }
        .disabled(action == nil)
    }
}

/// A small heading in the account menu.
struct AccountMenuCaption: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
    }
}

/// A menu-style row: full width, highlighted under the pointer.
struct MenuRow<Label: View>: View {
    var selected = false
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering && isEnabled ? Color.white.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

/// Which iPhone this window mirrors: every paired iPhone, the one used last
/// first, each with its own Connect. The app then starts touch control on
/// that iPhone and opens Screen Mirroring on it.
struct PhoneChooser: View {
    @ObservedObject var model: AppModel
    @ObservedObject var connector: PhoneMirrorConnector
    @ObservedObject private var windows = WindowRegistry.shared
    var compact = false
    @State private var refreshing = false

    private var phones: [PairedIPhone] {
        let last = model.lastConnectedDevice
        return model.discoveredIPhones.sorted { a, b in
            if (a.hardwareUDID == last) != (b.hardwareUDID == last) { return a.hardwareUDID == last }
            if a.isBooted != b.isBooted { return a.isBooted }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func window(using phone: PairedIPhone) -> String? {
        windows.models.first { $0 !== model && $0.preferredDeviceUDID == phone.hardwareUDID }?.receiver.receiverName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack {
                Text("Choose the iPhone")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    if refreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Refresh paired iPhones", comment: "Refresh button"))
            }
            VStack(spacing: 0) {
                if phones.isEmpty {
                    Text(refreshing ? "Looking for paired iPhones…"
                         : "No paired iPhone found. Pair one in Xcode › Device Hub (account menu › Connect a new iPhone).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                ForEach(Array(phones.enumerated()), id: \.element.id) { index, phone in
                    if index > 0 {
                        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 40)
                    }
                    row(phone)
                }
            }
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
            status
        }
        .task {
            // Phones come and go (Wi-Fi, asleep): keep the list fresh while shown.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func row(_ phone: PairedIPhone) -> some View {
        let usedBy = window(using: phone)
        let connectingThis = connector.connectingDevice == phone.hardwareUDID
        let lastUsed = phone.hardwareUDID == model.lastConnectedDevice
        return HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(phone.isBooted ? Palette.accent : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(phone.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
                Text(detail(phone, usedBy: usedBy, lastUsed: lastUsed))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if connectingThis {
                ProgressView().controlSize(.small)
            } else if usedBy == nil {
                Button {
                    Task { await connector.connect(model: model, phone: phone) }
                } label: {
                    Text("Connect")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Palette.accent.opacity(0.16), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(connector.isWorking || !phone.isBooted || model.isBusy)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 6 : 8)
        .opacity(phone.isBooted && usedBy == nil ? 1 : 0.55)
    }

    private func detail(_ phone: PairedIPhone, usedBy: String?, lastUsed: Bool) -> String {
        if let usedBy {
            return String(format: NSLocalizedString("In use by %@", comment: "Phone chooser"), usedBy)
        }
        if !phone.isBooted { return NSLocalizedString("Not reachable", comment: "Phone chooser") }
        var parts = [phone.modelName.isEmpty ? nil : phone.modelName,
                     phone.osVersion.isEmpty ? nil : "iOS " + phone.osVersion].compactMap { $0 }
        if lastUsed { parts.append(NSLocalizedString("used last", comment: "Phone chooser")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        switch connector.phase {
        case let .working(message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message)
            }
            .font(.caption)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            Text("\(AppBrand.current.name) starts touch control and Screen Mirroring on the iPhone you choose. It has to be unlocked.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refresh() async {
        refreshing = true
        await model.refreshPairedIPhones()
        refreshing = false
    }
}
