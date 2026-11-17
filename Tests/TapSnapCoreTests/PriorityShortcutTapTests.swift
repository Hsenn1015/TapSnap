import CoreGraphics
import XCTest
@testable import TapSnapSystem

@MainActor
final class PriorityShortcutTapTests: XCTestCase {
    private func makeTap(modifiers: UInt32 = GlobalShortcut.Combo.control) -> PriorityShortcutTap {
        PriorityShortcutTap(combo: .init(keyCode: 18, carbonModifiers: modifiers), onTrigger: {})
    }

    private func event(key: CGKeyCode = 18, flags: CGEventFlags = .maskControl,
                       down: Bool = true, repeatKey: Bool = false) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down))
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }

    func testExactCombinationTriggersAndCapsLockDoesNotChangeIt() throws {
        let tap = makeTap()
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event(flags: [.maskControl, .maskAlphaShift])), .trigger)
    }

    func testOtherKeysMissingAndAdditionalModifiersPassThrough() throws {
        let tap = makeTap()
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event(key: 19)), .passThrough)
        for flags: CGEventFlags in [[], .maskCommand, [.maskControl, .maskCommand],
                                   [.maskControl, .maskShift], [.maskControl, .maskAlternate]] {
            XCTAssertEqual(tap.decision(for: .keyDown, event: try event(flags: flags)), .passThrough)
        }
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(down: false)), .passThrough)
    }

    func testAllFourConfiguredModifiersMustMatch() throws {
        let tap = makeTap(modifiers: GlobalShortcut.Combo.control | GlobalShortcut.Combo.command
                          | GlobalShortcut.Combo.option | GlobalShortcut.Combo.shift)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event(flags: [.maskControl, .maskCommand, .maskAlternate])), .passThrough)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event(flags: [.maskControl, .maskCommand, .maskAlternate, .maskShift])), .trigger)
    }

    func testRepeatsAreConsumedWithoutTriggeringAgain() throws {
        let tap = makeTap()
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .trigger)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event(repeatKey: true)), .consume)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .consume)
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(down: false)), .consume)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .trigger)
    }

    func testKeyUpOnlyConsumedForPreviouslyMatchedKeyEvenAfterControlReleased() throws {
        let tap = makeTap()
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(down: false)), .passThrough)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .trigger)
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(key: 19, flags: [], down: false)), .passThrough)
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(flags: [], down: false)), .consume)
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(flags: [], down: false)), .passThrough)
    }

    func testRepeatWithoutObservedPressDoesNotTriggerOrCaptureRelease() throws {
        let tap = makeTap()
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event(repeatKey: true)), .consume)
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(down: false)), .passThrough)
    }

    func testCapturedKeyDoesNotLeakRepeatsWhenModifiersChange() throws {
        let tap = makeTap()
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .trigger)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event(flags: [], repeatKey: true)), .consume)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event(flags: [.maskControl, .maskShift], repeatKey: true)), .consume)
        XCTAssertEqual(tap.decision(for: .flagsChanged, event: try event(flags: [])), .passThrough)
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(flags: [], down: false)), .consume)
    }

    func testSecureInputPassesTheCombinationAndClearsAHeldKeyWithoutRelease() throws {
        let tap = makeTap()
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .trigger)

        tap.updateSecureInput(secureInputEnabled: true)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event(repeatKey: true)), .passThrough)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .passThrough)

        tap.updateSecureInput(secureInputEnabled: false)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .trigger)
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(down: false)), .consume)
    }

    func testSecureInputPassesMatchingReleaseAndUnchangedStatusKeepsOrdinaryHeldState() throws {
        let tap = makeTap()
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .trigger)
        tap.updateSecureInput(secureInputEnabled: false)
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .consume)

        tap.updateSecureInput(secureInputEnabled: true)
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(down: false)), .passThrough)
        tap.updateSecureInput(secureInputEnabled: false)
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(down: false)), .passThrough)
    }

    func testStopClearsHeldStateAndIsIdempotent() throws {
        let tap = makeTap()
        XCTAssertEqual(tap.decision(for: .keyDown, event: try event()), .trigger)
        tap.stop()
        tap.stop()
        XCTAssertFalse(tap.isRunning)
        XCTAssertEqual(tap.decision(for: .keyUp, event: try event(down: false)), .passThrough)
    }
}
