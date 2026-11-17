import AppKit
import XCTest
import TapSnapScreen
@testable import TapSnapApp

@MainActor
final class MultiDisplayOverlayTests: XCTestCase {
    private func currentScreens() throws -> [(NSScreen, ScreenDescriptor)] {
        _ = NSApplication.shared
        let descriptors = ScreenLayout.current()
        let screens = try NSScreen.screens.map { native in
            let number = try XCTUnwrap(native.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            let descriptor = try XCTUnwrap(descriptors.first { $0.id == number.uint32Value })
            return (native, descriptor)
        }
        guard !screens.isEmpty else { throw XCTSkip("需要连接 WindowServer 才能验证真实屏幕坐标") }
        return screens
    }

    private func makeOverlay(for descriptor: ScreenDescriptor) -> (SelectionOverlayWindow, SelectionOverlayView) {
        let window = SelectionOverlayWindow(screen: descriptor)
        window.isReleasedWhenClosed = false
        let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: descriptor.frame.size))
        window.contentView = view
        return (window, view)
    }

    func testOverlayFrameMatchesEachNativeScreenIncludingFullHeight() throws {
        for (native, descriptor) in try currentScreens() {
            let (window, view) = makeOverlay(for: descriptor)
            defer { view.stopBorderAnimation(); window.contentView = nil; window.close() }
            let context = "display=\(descriptor.id) scale=\(descriptor.scale) safeAreaTop=\(native.safeAreaInsets.top) CG=\(descriptor.frame) AppKit=\(native.frame) window=\(window.frame) content=\(view.frame)"
            print(context)
            XCTAssertFalse(window.isVisible, "测试不得显示覆盖层")
            XCTAssertEqual(window.frame, native.frame, context)
            XCTAssertEqual(view.frame, CGRect(origin: .zero, size: native.frame.size), context)
            XCTAssertEqual(view.bounds, CGRect(origin: .zero, size: native.frame.size), context)
        }
    }

    func testOverlayContentConvertsToNativeScreenCoordinatesWithoutOffset() throws {
        for (native, descriptor) in try currentScreens() {
            let (window, view) = makeOverlay(for: descriptor)
            defer { view.stopBorderAnimation(); window.contentView = nil; window.close() }
            // 真实 AppKit 坐标换算覆盖整个画布及一个非零局部区域；不发送系统事件。
            let contentOnScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
            XCTAssertEqual(contentOnScreen, native.frame, "display=\(descriptor.id)，画布不能因菜单栏、刘海或坐标原点平移")
            let local = CGRect(x: 40, y: 60, width: 120, height: 80)
            let selectionOnScreen = window.convertToScreen(view.convert(local, to: nil))
            XCTAssertEqual(selectionOnScreen, local.offsetBy(dx: native.frame.minX, dy: native.frame.minY),
                           "display=\(descriptor.id)，局部框选必须落在该屏幕的真实位置")
            XCTAssertFalse(window.isVisible)
        }
    }

    func testAppKitFrameConversionForDisplaysAboveBelowLeftAndRight() {
        let layouts: [(String, CGRect, CGRect)] = [
            ("primary", CGRect(x: 0, y: 0, width: 1920, height: 1080),
             CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            ("left", CGRect(x: -1512, y: 0, width: 1512, height: 982),
             CGRect(x: -1512, y: 98, width: 1512, height: 982)),
            ("right", CGRect(x: 1920, y: 0, width: 1280, height: 800),
             CGRect(x: 1920, y: 280, width: 1280, height: 800)),
            ("above", CGRect(x: 0, y: -900, width: 1440, height: 900),
             CGRect(x: 0, y: 1080, width: 1440, height: 900)),
            ("below", CGRect(x: 0, y: 1080, width: 1920, height: 1200),
             CGRect(x: 0, y: -1200, width: 1920, height: 1200)),
            ("staggered-left", CGRect(x: -1280, y: 220, width: 1280, height: 720),
             CGRect(x: -1280, y: 140, width: 1280, height: 720)),
            ("staggered-right", CGRect(x: 1920, y: -250, width: 1280, height: 800),
             CGRect(x: 1920, y: 530, width: 1280, height: 800)),
        ]
        for (name, cgFrame, expected) in layouts {
            for scale: CGFloat in [1, 2] {
                // isMain 是当前键盘焦点所在屏幕，不能代替固定的主显示器坐标原点。
                for isMain in [false, true] {
                    let screen = ScreenDescriptor(id: 42, frame: cgFrame,
                                                  visibleFrame: expected.insetBy(dx: 0, dy: 32),
                                                  scale: scale, isMain: isMain, localizedName: name)
                    XCTAssertEqual(screen.appKitFrame(primaryDisplayHeight: 1080), expected,
                                   "\(name), scale=\(scale), isMain=\(isMain)")
                    XCTAssertEqual(screen.frame, cgFrame, "捕获 API 仍需要原来的 CG 坐标")
                }
            }
        }
    }

    func testAppKitFrameConversionWhenBuiltInDisplayBecomesPrimary() {
        let builtIn = ScreenDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       visibleFrame: .zero, scale: 2, isMain: false, localizedName: "Built-in")
        let external = ScreenDescriptor(id: 3, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                        visibleFrame: .zero, scale: 1, isMain: true, localizedName: "External")
        XCTAssertEqual(builtIn.appKitFrame(primaryDisplayHeight: 982),
                       CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(external.appKitFrame(primaryDisplayHeight: 982),
                       CGRect(x: 1512, y: -98, width: 1920, height: 1080))
    }

    func testCroppingOffsetDisplayStillUsesCGCoordinatesAndBackingScale() throws {
        for scale in [1, 2] {
            let width = 100 * scale
            let height = 80 * scale
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    bytes[offset] = UInt8(x)
                    bytes[offset + 1] = UInt8(y)
                    bytes[offset + 2] = 17
                    bytes[offset + 3] = 255
                }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                              bitsPerPixel: 32, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                              provider: provider, decode: nil, shouldInterpolate: false,
                                              intent: .defaultIntent))
            let screen = ScreenDescriptor(id: 42, frame: CGRect(x: -100, y: -300, width: 100, height: 80),
                                          visibleFrame: .zero, scale: CGFloat(scale), isMain: false,
                                          localizedName: "Offset display")
            var session = ScreenshotSession(mode: .region)
            session.frames = [CapturedFrame(screen: screen, image: image)]
            session.targetScreen = screen
            // CG 全局选区对应该屏左上角 (20, 30)，不可混入 AppKit 的屏幕原点。
            session.selectionRect = CGRect(x: -80, y: -270, width: 10, height: 12)
            let cropped = try XCTUnwrap(session.croppedImage())
            XCTAssertEqual(cropped.width, 10 * scale)
            XCTAssertEqual(cropped.height, 12 * scale)
            let bitmap = NSBitmapImageRep(cgImage: cropped)
            for point in [(0, 0), (cropped.width - 1, cropped.height - 1)] {
                let color = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(color.redComponent * 255, CGFloat(20 * scale + point.0), accuracy: 0.01)
                XCTAssertEqual(color.greenComponent * 255, CGFloat(30 * scale + point.1), accuracy: 0.01)
            }
        }
    }
}
