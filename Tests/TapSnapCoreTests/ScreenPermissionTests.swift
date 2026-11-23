import ScreenCaptureKit
import TapSnapScreen
import XCTest
@testable import TapSnapApp

final class ScreenPermissionTests: XCTestCase {
    func testOnlyAGrantOrAnExplicitContinueCanResume() {
        XCTAssertEqual(ScreenPermissionNextStep.decide(currentGrant: false, freshGrant: false,
            captureRejected: false, userConfirmed: false, mayReopenAutomatically: true), .wait)
        XCTAssertEqual(ScreenPermissionNextStep.decide(currentGrant: true, freshGrant: true,
            captureRejected: false, userConfirmed: false, mayReopenAutomatically: true), .resume)
        XCTAssertEqual(ScreenPermissionNextStep.decide(currentGrant: false, freshGrant: true,
            captureRejected: false, userConfirmed: false, mayReopenAutomatically: true), .reopen)
        XCTAssertEqual(ScreenPermissionNextStep.decide(currentGrant: true, freshGrant: true,
            captureRejected: true, userConfirmed: false, mayReopenAutomatically: true), .reopen)
    }

    func testAnUnusableGrantAfterReopeningDoesNotRestartAgain() {
        XCTAssertEqual(ScreenPermissionNextStep.decide(currentGrant: false, freshGrant: true,
            captureRejected: false, userConfirmed: false, mayReopenAutomatically: false), .wait)
        XCTAssertEqual(ScreenPermissionNextStep.decide(currentGrant: false, freshGrant: false,
            captureRejected: false, userConfirmed: true, mayReopenAutomatically: false), .reopen)
    }

    func testRelaunchKeepsTheRequestedActionAndPrivacyOptions() throws {
        let capture = PendingScreenCapture(outcome: .longShot, options: .init(format: "png", autoSave: true),
            forcePrivacy: true, rect: CGRect(x: -20, y: 30, width: 180, height: 100), displayID: 2)
        let continuation = ScreenPermissionContinuation(capture: capture, previousApp: 21)
        let args = ["TapSnap", ScreenPermissionContinuation.resumeArgument, try continuation.launchArgument()]
        XCTAssertEqual(ScreenPermissionContinuation.fromArguments(args), continuation)
        XCTAssertNil(ScreenPermissionContinuation.fromArguments(Array(args.dropLast())))
        XCTAssertNil(ScreenPermissionContinuation.fromArguments(["TapSnap"]))
    }

    func testScreenCaptureKitDenialUsesThePermissionGuide() {
        let denial = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertTrue(CaptureError.isPermissionDenied(CaptureError.permissionDenied))
        XCTAssertTrue(CaptureError.isPermissionDenied(denial))
        XCTAssertFalse(CaptureError.isPermissionDenied(CaptureError.noDisplays))
    }
}
