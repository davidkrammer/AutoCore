import AppKit
import XCTest
@testable import AutoCore

@MainActor
final class PhoneKeyboardTests: XCTestCase {
    func testPassesTextDeleteReturnAndArrows() {
        XCTAssertEqual(PhoneKeys.text(for: "a", modifiers: []), "a")
        XCTAssertEqual(PhoneKeys.text(for: "Ä", modifiers: [.shift]), "Ä")
        XCTAssertEqual(PhoneKeys.text(for: "@", modifiers: [.option]), "@")
        XCTAssertEqual(PhoneKeys.text(for: "\u{7F}", modifiers: []), "\u{7F}")
        XCTAssertEqual(PhoneKeys.text(for: "\r", modifiers: []), "\r")
        XCTAssertEqual(PhoneKeys.text(for: "\u{3}", modifiers: [.numericPad]), "\r")
        XCTAssertEqual(PhoneKeys.text(for: "\u{F702}", modifiers: [.function, .numericPad]), "\u{F702}")
    }

    func testMacKeepsShortcutsEscapeTabAndFunctionKeys() {
        XCTAssertNil(PhoneKeys.text(for: "r", modifiers: [.command]))
        XCTAssertNil(PhoneKeys.text(for: "a", modifiers: [.control]))
        XCTAssertNil(PhoneKeys.text(for: "\u{1B}", modifiers: []))
        XCTAssertNil(PhoneKeys.text(for: "\t", modifiers: []))
        XCTAssertNil(PhoneKeys.text(for: "\u{F704}", modifiers: [.function]))
        XCTAssertNil(PhoneKeys.text(for: "", modifiers: []))
    }

    func testPastesOneLine() {
        XCTAssertEqual(PhoneKeys.pasted(" Selii1602\nSarge2220 \n"), "Selii1602 Sarge2220")
        XCTAssertNil(PhoneKeys.pasted("\n \n"))
        XCTAssertEqual(PhoneKeys.display("ab\u{7F}\r"), "ab⌫⏎")
    }

    func testMirrorCatchesKeysOnlyWhileItHasTheKeyboard() throws {
        let keyboard = PhoneKeyboard()
        var typed: [String] = []
        let view = PhoneKeyCatcherView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.keyboard = keyboard
        view.onText = { typed.append($0); return true }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.contentView?.addSubview(field)
        defer { window.close() }

        func press(_ characters: String, keyCode: UInt16 = 0) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            NSApp.sendEvent(event)
        }

        // Nothing but a click on the mirror hands it the keyboard.
        window.makeFirstResponder(view)
        XCTAssertFalse(window.firstResponder === view)
        XCTAssertFalse(keyboard.isFocused)

        keyboard.view = view
        keyboard.focus()
        XCTAssertTrue(keyboard.isFocused)
        try press("a")
        try press("\r", keyCode: 36)
        XCTAssertEqual(typed, ["a", "\r"])

        try press("\u{1B}", keyCode: 53)
        XCTAssertFalse(keyboard.isFocused)
        try press("b")
        XCTAssertEqual(typed, ["a", "\r"])

        window.makeFirstResponder(view)
        XCTAssertFalse(window.firstResponder === view)

        // A Mac text field takes the keyboard back.
        keyboard.focus()
        XCTAssertTrue(keyboard.isFocused)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(keyboard.isFocused)
    }
}
