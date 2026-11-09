import AppKit
import SwiftUI

/// Which Mac key presses go to the iPhone, and as what. XCTest's key
/// constants are AppKit's characters (Delete U+007F, Return U+000D, the
/// arrows U+F700…U+F703, Forward Delete U+F728), so keys pass through as
/// typed and arrive like a hardware keyboard on the iPhone.
enum PhoneKeys {
    /// The text for one key press, or nil when the Mac keeps the key
    /// (⌘/⌃ shortcuts, Escape, Tab, function keys).
    static func text(for characters: String?, modifiers: NSEvent.ModifierFlags) -> String? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control]), let characters, !characters.isEmpty else { return nil }
        var result = ""
        for scalar in characters.unicodeScalars {
            switch scalar.value {
            case 0x7F, 0x0D, 0xF700...0xF703, 0xF728:
                result.unicodeScalars.append(scalar)
            case 0x03:
                result += "\r" // Enter on the number pad
            case 0x00...0x1F, 0xF704...0xF8FF:
                return nil
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Pasted text as one line, so a pasted list never presses Return.
    static func pasted(_ string: String) -> String? {
        let line = string.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return String(line.prefix(200))
    }

    /// Typed text as shown on the mirror while it travels to the iPhone.
    static func display(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x7F: return "⌫"
            case 0xF728: return "⌦"
            case 0x0D: return "⏎"
            case 0xF700: return "↑"
            case 0xF701: return "↓"
            case 0xF702: return "←"
            case 0xF703: return "→"
            default: return String(scalar)
            }
        }.joined().suffix(24))
    }
}

/// The Mac keyboard as the iPhone's keyboard. Clicking the mirror gives it
/// the keyboard; Escape or clicking a text field on the Mac takes it back.
/// Keys typed while a request is on its way are sent together next.
@MainActor
final class PhoneKeyboard: ObservableObject {
    @Published fileprivate(set) var isFocused = false
    @Published private var sending = ""
    @Published private var queued = ""
    @Published private(set) var problem: String?
    weak var view: PhoneKeyCatcherView?
    private var worker: Task<Void, Never>?

    /// The keys on their way to the iPhone, for the mirror's chip.
    var echo: String { PhoneKeys.display(sending + queued) }

    func focus() {
        guard let view, let window = view.window, window.firstResponder !== view else { return }
        view.mayTakeKeyboard = true
        if !window.makeFirstResponder(view) { view.mayTakeKeyboard = false }
    }

    func type(_ text: String, using send: @escaping (String) async throws -> Void) {
        queued += text
        problem = nil
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let chunk = self?.nextChunk() {
                do {
                    try await send(chunk)
                } catch {
                    self?.fail(error)
                }
            }
        }
    }

    private func nextChunk() -> String? {
        sending = ""
        guard !queued.isEmpty else {
            worker = nil
            return nil
        }
        sending = queued
        queued = ""
        return sending
    }

    private func fail(_ error: Error) {
        queued = ""
        problem = error.localizedDescription
    }

    fileprivate func setFocused(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        if !focused { problem = nil }
    }
}

/// An invisible view behind the mirror that holds the Mac's keyboard focus.
struct PhoneKeyCatcher: NSViewRepresentable {
    @ObservedObject var keyboard: PhoneKeyboard
    /// Sends the text and returns true, or returns false when typing on the
    /// iPhone isn't possible right now (the Mac then handles the key).
    let onText: (String) -> Bool

    func makeNSView(context: Context) -> PhoneKeyCatcherView {
        let view = PhoneKeyCatcherView()
        view.keyboard = keyboard
        keyboard.view = view
        view.onText = onText
        return view
    }

    func updateNSView(_ view: PhoneKeyCatcherView, context: Context) {
        view.keyboard = keyboard
        keyboard.view = view
        view.onText = onText
    }
}

final class PhoneKeyCatcherView: NSView, NSMenuItemValidation {
    weak var keyboard: PhoneKeyboard?
    var onText: ((String) -> Bool)?
    private var monitor: Any?

    /// Only a click on the mirror hands over the keyboard, never the
    /// window picking a first responder when it opens.
    var mayTakeKeyboard = false

    override var acceptsFirstResponder: Bool { mayTakeKeyboard }

    override func becomeFirstResponder() -> Bool {
        guard mayTakeKeyboard else { return false }
        keyboard?.setFocused(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        mayTakeKeyboard = false
        keyboard?.setFocused(false)
        return true
    }

    // Keys are caught before AppKit dispatches them, so Return reaches the
    // iPhone instead of a window's default button.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  window.firstResponder === self else { return event }
            if event.keyCode == 53 { // Escape
                window.makeFirstResponder(nil)
                return nil
            }
            // While a run owns the iPhone, keys stay with the Mac.
            guard let text = PhoneKeys.text(for: event.characters, modifiers: event.modifierFlags),
                  self.onText?(text) == true else { return event }
            return nil
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string),
              let text = PhoneKeys.pasted(string), onText?(text) == true else {
            NSSound.beep()
            return
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) {
            return NSPasteboard.general.string(forType: .string) != nil
        }
        return true
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Over the iPhone's notch while the Mac keyboard types on the iPhone.
struct PhoneKeyboardChip: View {
    @ObservedObject var keyboard: PhoneKeyboard

    var body: some View {
        HStack(spacing: 6) {
            if let problem = keyboard.problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warning)
                Text(problem)
                    .lineLimit(1)
            } else {
                Image(systemName: "keyboard")
                    .foregroundStyle(Palette.accent)
                if keyboard.echo.isEmpty {
                    Text("Typing on iPhone")
                    Text("esc")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: 1))
                        .foregroundStyle(.secondary)
                } else {
                    Text(keyboard.echo)
                        .lineLimit(1)
                        .truncationMode(.head)
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}
