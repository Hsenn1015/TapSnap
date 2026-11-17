import Foundation
import XCTest
@testable import TapSnapMedia

private final class MicrophoneTestState {
    private let lock = NSLock()
    private var permissionCallbacks: [(Bool) -> Void] = []
    private var operations: [String] = []
    var onRequest: (() -> Void)?
    var onRun: (() -> Void)?
    var onStop: (() -> Void)?

    func request(_ callback: @escaping (Bool) -> Void) {
        lock.lock()
        permissionCallbacks.append(callback)
        lock.unlock()
        onRequest?()
    }

    func resolve(_ index: Int, granted: Bool) {
        lock.lock()
        let callback = permissionCallbacks[index]
        lock.unlock()
        callback(granted)
    }

    func run() {
        lock.lock()
        operations.append("start")
        lock.unlock()
        onRun?()
    }

    func stop() {
        lock.lock()
        operations.append("stop")
        lock.unlock()
        onStop?()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return operations
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return permissionCallbacks.count
    }

    func makeCapture() -> MicrophoneCapture {
        MicrophoneCapture(requestAccess: request, runSession: { _ in self.run() },
                          stopSession: { _ in self.stop() })
    }
}

final class MicrophoneCaptureTests: XCTestCase {
    func testGrantAfterStopDoesNotStartMicrophone() async {
        let state = MicrophoneTestState()
        let requested = expectation(description: "等待权限")
        let stopped = expectation(description: "取消与队列排空")
        stopped.expectedFulfillmentCount = 2
        state.onRequest = { requested.fulfill() }
        state.onStop = { stopped.fulfill() }
        let capture = state.makeCapture()
        capture.start()
        await fulfillment(of: [requested], timeout: 2)
        capture.stop()
        state.resolve(0, granted: true)
        capture.stop()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(state.events, ["stop", "stop"])
    }

    func testPreviousGrantCannotStartNewDeniedAttempt() async {
        let state = MicrophoneTestState()
        let requested = expectation(description: "两次权限请求")
        requested.expectedFulfillmentCount = 2
        let stopped = expectation(description: "两次停止")
        stopped.expectedFulfillmentCount = 2
        state.onRequest = { requested.fulfill() }
        state.onStop = { stopped.fulfill() }
        let capture = state.makeCapture()
        capture.start()
        capture.stop()
        capture.start()
        await fulfillment(of: [requested], timeout: 2)
        state.resolve(0, granted: true)
        state.resolve(1, granted: false)
        capture.stop()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(state.events, ["stop", "stop"])
    }

    func testDuplicateStartRequestsOnlyOnePermissionAndStopsAfterRun() async {
        let state = MicrophoneTestState()
        let requested = expectation(description: "一次权限请求")
        requested.assertForOverFulfill = false
        let running = expectation(description: "授权后启动")
        let stopped = expectation(description: "启动后停止")
        state.onRequest = { requested.fulfill() }
        state.onRun = { running.fulfill() }
        state.onStop = { stopped.fulfill() }
        let capture = state.makeCapture()
        capture.start()
        capture.start()
        await fulfillment(of: [requested], timeout: 2)
        state.resolve(0, granted: true)
        await fulfillment(of: [running], timeout: 2)
        capture.stop()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(state.events, ["start", "stop"])
        XCTAssertEqual(state.requestCount, 1)
    }
}
