import AppKit
import TapSnapConfig
import XCTest
@testable import TapSnapApp

@MainActor
final class SettingsAppearanceTests: XCTestCase {
    func testSettingsWindowAndHostedControlsFollowAppTheme() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("设置窗口测试需要 macOS WindowServer") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        config.update { $0.appearance.useDarkTheme = false }
        let environment = AppEnvironment(config: config)
        environment.openSettings()
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "TapSnap 设置" })
        defer { window.close() }

        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
        XCTAssertEqual(window.appearance?.name, .aqua)
        XCTAssertEqual(window.contentView?.effectiveAppearance.bestMatch(from: appearances), .aqua)

        config.update { $0.appearance.useDarkTheme = true }
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertEqual(window.contentView?.effectiveAppearance.bestMatch(from: appearances), .darkAqua)

        environment.openSettings(section: .privacy)
        XCTAssertEqual(window.contentView?.effectiveAppearance.bestMatch(from: appearances), .darkAqua)

        window.close()
        config.update { $0.appearance.useDarkTheme = false }
        environment.openSettings()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.appearance?.name, .aqua)
        XCTAssertEqual(window.contentView?.effectiveAppearance.bestMatch(from: appearances), .aqua)
    }
}
