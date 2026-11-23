import ScreenCaptureKit
@testable import TapSnapScreen
import XCTest
@testable import TapSnapApp

final class ScreenPermissionTests: XCTestCase {
    func testAccessCheckUsesLiveResultAndDistinguishesAnUnrelatedFailure() async {
        let granted = await ScreenAccessCheck.run { }
        let denied = await ScreenAccessCheck.run {
            throw NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        }
        let unavailable = await ScreenAccessCheck.run { throw CaptureError.noDisplays }
        XCTAssertEqual(granted, .available)
        XCTAssertEqual(denied, .denied)
        XCTAssertEqual(unavailable, .failed(CaptureError.noDisplays.localizedDescription))
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

    func testExplicitAccessCheckRecognizesScreenCaptureKitDenial() async {
        let denial = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let service = ScreenCaptureService(loadContent: { throw denial })
        do {
            try await service.checkAccess()
            XCTFail("缺少屏幕录制权限时，检查应返回拒绝")
        } catch {
            XCTAssertTrue(CaptureError.isPermissionDenied(error))
        }
    }

    func testCaptureReportsServiceFailureWithoutAskingForPermission() async {
        let failure = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.failedToStart.rawValue)
        let service = ScreenCaptureService(loadContent: { throw failure })
        do {
            _ = try await service.captureAllScreens()
            XCTFail("屏幕采集服务出错时，应报告原始错误")
        } catch {
            XCTAssertFalse(CaptureError.isPermissionDenied(error))
            guard case CaptureError.captureFailed(let underlying?) = error else {
                return XCTFail("应保留 ScreenCaptureKit 失败原因")
            }
            XCTAssertEqual(underlying as NSError, failure)
        }
    }
}
