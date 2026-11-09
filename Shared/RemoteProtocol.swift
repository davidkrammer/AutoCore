import Foundation

/// The Remote: an iPhone app that shows and steers what the Mac app shows. The Mac owns every setting and run; the Remote only renders what
/// the Mac describes (`RemoteState`) and sends back what was tapped
/// (`RemoteCommand`). New Mac options therefore need no Remote update.
enum RemoteWire {
    /// The Bonjour type both apps list under NSBonjourServices in their
    /// Info.plist ("_<app>-remote._tcp"), so each app finds only its own.
    static let serviceType: String = {
        let services = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
        return services.first { $0.hasSuffix("-remote._tcp") } ?? "_autocore-remote._tcp"
    }()
    /// "<app>-remote": mixed into every key, so the apps never mix up.
    static var label: String { String(serviceType.dropFirst().dropLast("._tcp".count)) }
    static let version = 1
    /// Largest message, a mirror frame included.
    static let maximumMessageBytes = 8 << 20
}

// MARK: - What the Mac shows

/// The whole picture for one Remote: every window, and the panel of
/// the window and tab the Remote looks at.
struct RemoteState: Codable, Equatable {
    var macName: String
    var appVersion: String
    var windows: [RemoteWindow]
    /// The window the panels below belong to.
    var window: UUID?
    var mode: String?
    var panel: RemotePanel?
    /// The window's iPhone, account and connection: the Mac's account menu.
    var setup: RemotePanel?
}

/// One window on the Mac, with the iPhone it mirrors.
struct RemoteWindow: Codable, Equatable, Identifiable {
    var id: UUID
    /// The AirPlay name, e.g. "AutoCore#1111".
    var name: String
    /// The account signed in on the iPhone, as the Mac shows it.
    var account: String?
    var accountConfirmed: Bool
    var phone: String?
    /// "ready", "working", "off" or "problem".
    var link: String
    var linkSummary: String
    var mirroring: Bool
    var controlReady: Bool
    var busy: Bool
    /// The tab a run locks the window to, if one runs.
    var lockedMode: String?
    /// The tab the Mac window shows.
    var selectedMode: String
    /// Width / height of the mirrored picture.
    var aspect: Double
    /// One line about what runs, e.g. "Opening App Store…".
    var activity: String?
    var modes: [RemoteOption]
}

/// A panel as a list of blocks, drawn natively by the Remote.
struct RemotePanel: Codable, Equatable {
    var title: String
    var subtitle: String?
    var counter: RemoteStat?
    var blocks: [RemoteBlock]
}

struct RemoteBlock: Codable, Equatable, Identifiable {
    var id: String
    var kind: Kind

    enum Kind: Codable, Equatable {
        /// Big numbers side by side ("Read 12 · Tapped 3").
        case stats([RemoteStat])
        /// A run or an armed start: pill, headline, counters, Stop.
        case status(RemoteStatus)
        /// One line with a symbol, e.g. what is missing before a start.
        case notice(RemoteNotice)
        /// Buttons in a row; the first primary one spans the width.
        case actions([RemoteAction])
        /// Settings.
        case section(RemoteSection)
        case goal(RemoteGoal)
        case rows(RemoteRows)
    }

    init(_ id: String, _ kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

struct RemoteStat: Codable, Equatable {
    var title: String
    var value: String
    var footnote: String?
    var tint: String?
}

struct RemoteStatus: Codable, Equatable {
    /// "RUNNING", "PAUSED" …
    var pill: String
    var tint: String
    var title: String
    var detail: String?
    var symbol: String?
    /// Shown as a running timer.
    var since: Date?
    /// Shown as a countdown.
    var until: Date?
    var progress: Double?
    var counters: [RemoteStat] = []
    var actions: [RemoteAction] = []
}

struct RemoteNotice: Codable, Equatable {
    var text: String
    var symbol: String
    var tint: String
}

struct RemoteAction: Codable, Equatable, Identifiable {
    enum Style: String, Codable { case primary, secondary, destructive }

    var id: String
    var title: String
    var symbol: String?
    var style: Style = .secondary
    var tint: String?
    var subtitle: String?
    var enabled = true
    /// Asked in an alert before the action runs.
    var confirm: String?
}

struct RemoteSection: Codable, Equatable {
    var title: String?
    var footer: String?
    var controls: [RemoteControl]
    var enabled = true
}

struct RemoteOption: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var title: String
    var symbol: String?
    var tint: String?
    var image: String?
}

struct RemoteControl: Codable, Equatable, Identifiable {
    /// The setting's key; changes come back with it.
    var id: String
    var kind: Kind

    enum ChoiceStyle: String, Codable { case segmented, menu }

    enum Kind: Codable, Equatable {
        case toggle(title: String, value: Bool)
        case choice(title: String?, options: [RemoteOption], value: String, style: ChoiceStyle)
        /// Chips; any number on. `minimum` of them stay on.
        case multi(title: String?, options: [RemoteOption], values: [String], minimum: Int)
        /// `format` holds one %d; `zeroTitle` replaces 0 ("No limit").
        case number(title: String, value: Int, minimum: Int, maximum: Int, step: Int,
                    format: String?, zeroTitle: String?)
        case text(title: String, value: String, placeholder: String)
        case info(title: String, value: String)
        case note(String)
        case button(RemoteAction)
    }

    init(_ id: String, _ kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// Progress towards a goal with a count (e.g. a badge to earn).
struct RemoteGoal: Codable, Equatable {
    var title: String
    var count: Int?
    var goal: Int
    var detail: String
    var estimate: String?
    /// Key to type the count in, like "Correct" on the Mac.
    var editKey: String?
}

struct RemoteRows: Codable, Equatable {
    var title: String?
    var rows: [RemoteRow]
    var empty: String?
    var footer: String?
}

struct RemoteRow: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String?
    var trailing: String?
    var symbol: String?
    var image: String?
    var tint: String?
    var checked: Bool?
    /// Sent as an action when the row is tapped.
    var action: String?
    var enabled = true
}

// MARK: - What the Remote sends

enum RemoteValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case strings([String])
}

enum RemoteCommand: Codable, Equatable {
    /// The window and tab to describe, and whether to stream its mirror.
    case watch(window: UUID?, mode: String?, frames: Bool)
    /// One received frame; the Mac keeps two in flight at most.
    case frameReceived
    case tap(window: UUID, x: Double, y: Double)
    case drag(window: UUID, fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double)
    case type(window: UUID, text: String)
    case set(window: UUID, key: String, value: RemoteValue)
    case action(window: UUID, id: String)
    case ping
}

enum RemoteEvent: Codable, Equatable {
    case state(RemoteState)
    /// The answer to a tap, a setting or an action.
    case result(ok: Bool, message: String)
    /// Pairing accepted; reconnect with the new key.
    case paired(macID: UUID)
    case pong
}

// MARK: - Handshake (before encryption)

struct RemoteHello: Codable {
    var version: Int
    var remoteID: UUID
    var name: String
    var model: String
    /// Whether this Remote holds a key for the Mac it connects to.
    var hasKey: Bool
    var publicKey: Data
    var nonce: Data
}

struct RemoteWelcome: Codable {
    enum Mode: String, Codable { case session, pairing, rejected }

    var version: Int
    var macID: UUID
    var macName: String
    var mode: Mode
    var publicKey: Data
    var nonce: Data
    var message: String?
}

/// Binary message kinds inside the encrypted channel.
enum RemotePayloadKind: UInt8 {
    case json = 1
    /// 16-byte window id, then a JPEG.
    case frame = 2
}
