import Foundation
import XCTest
@testable import TapSnapApp

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testBackgroundReminderWaitsForIdleAndIsDeliveredOncePerBuild() async throws {
        let defaults = try makeDefaults()
        var busy = true
        var reminders: [String] = []
        let updater = AppUpdater(isBusy: { busy }, notify: { reminders.append($0) }, defaults: defaults)

        updater.queueReminder(build: "6", version: "0.1.5")
        XCTAssertFalse(updater.canCheckForUpdates)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(updater.availableVersion)
        XCTAssertTrue(reminders.isEmpty)

        busy = false
        try await waitUntil { updater.availableVersion != nil }
        XCTAssertEqual(updater.availableVersion, "0.1.5")
        XCTAssertEqual(reminders.count, 1)
        XCTAssertTrue(updater.canCheckForUpdates)

        updater.standardUserDriverWillFinishUpdateSession()
        XCTAssertNil(updater.availableVersion)
        updater.queueReminder(build: "6", version: "0.1.5")
        XCTAssertEqual(updater.availableVersion, "0.1.5")
        XCTAssertEqual(reminders.count, 1)
    }

    func testConfirmedRestartIsDeferredWithoutLaunchingAnUnconfirmedRestart() async throws {
        var busy = true
        var restarts = 0
        let updater = AppUpdater(isBusy: { busy }, notify: { _ in }, defaults: try makeDefaults())
        updater.queueReminder(build: "7", version: "0.1.6")
        XCTAssertEqual(restarts, 0)

        XCTAssertTrue(updater.postponeRelaunchIfBusy { restarts += 1 })
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(restarts, 0)
        busy = false
        try await waitUntil { restarts == 1 }
        XCTAssertEqual(restarts, 1)
        XCTAssertNil(updater.availableVersion)
    }

    private func makeDefaults() throws -> UserDefaults {
        let key = "TapSnap-AppUpdaterTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        addTeardownBlock { defaults.removePersistentDomain(forName: key) }
        return defaults
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<30 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("等待空闲操作超时")
    }
}
