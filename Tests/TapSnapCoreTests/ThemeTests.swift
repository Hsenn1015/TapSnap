import XCTest
import TapSnapCore
@testable import TapSnapTheme

/// oklch -> sRGB 的转换是整套 shadcn 配色的地基，
/// 这里挑几个有代表性的 token 对照官方 CSS 的换算结果。
final class ColorTokenTests: XCTestCase {
    func testPureWhiteAndBlack() {
        let white = ColorConversion.sRGB(from: OKLCH(1, 0, 0))
        XCTAssertEqual(white.red, 1, accuracy: 0.005)
        XCTAssertEqual(white.green, 1, accuracy: 0.005)
        XCTAssertEqual(white.blue, 1, accuracy: 0.005)

        let black = ColorConversion.sRGB(from: OKLCH(0, 0, 0))
        XCTAssertEqual(black.red, 0, accuracy: 0.005)
        XCTAssertEqual(black.green, 0, accuracy: 0.005)
        XCTAssertEqual(black.blue, 0, accuracy: 0.005)
    }

    /// 浅色主题的 foreground：oklch(0.145 0 0) ≈ rgb(10, 10, 10)。
    func testNeutralForeground() {
        let foreground = DesignTokens.lightValue(.foreground)
        XCTAssertEqual(foreground.red, 10.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(foreground.green, 10.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(foreground.blue, 10.0 / 255.0, accuracy: 0.01)
    }

    /// 浅色主题的 muted-foreground：oklch(0.556 0 0) ≈ rgb(115,115,115)。
    func testMutedForeground() {
        let muted = DesignTokens.lightValue(.mutedForeground)
        XCTAssertEqual(muted.red, 115.0 / 255.0, accuracy: 0.02)
    }

    /// 深色主题的 border 带 10% 透明度。
    func testDarkBorderAlpha() {
        let border = DesignTokens.darkValue(.border)
        XCTAssertEqual(border.alpha, 0.10, accuracy: 0.001)
        XCTAssertEqual(border.red, 1, accuracy: 0.005)
    }

    /// 所有 token 在两种主题下都能落到合法区间。
    func testAllTokensInGamut() {
        for token in DesignToken.allCases {
            for color in [DesignTokens.lightValue(token), DesignTokens.darkValue(token)] {
                XCTAssertTrue((0...1).contains(color.red), "\(token) 红通道越界")
                XCTAssertTrue((0...1).contains(color.green), "\(token) 绿通道越界")
                XCTAssertTrue((0...1).contains(color.blue), "\(token) 蓝通道越界")
            }
        }
    }

    /// 核心语义色应当真的有对比：浅色主题下 background 比 foreground 亮。
    func testLightThemeContrast() {
        let background = DesignTokens.lightValue(.background)
        let foreground = DesignTokens.lightValue(.foreground)
        XCTAssertGreaterThan(background.red, foreground.red)
    }

    /// 深色主题反过来。
    func testDarkThemeContrast() {
        let background = DesignTokens.darkValue(.background)
        let foreground = DesignTokens.darkValue(.foreground)
        XCTAssertLessThan(background.red, foreground.red)
    }

    func testRadiusScale() {
        XCTAssertEqual(DesignTokens.radiusSM, DesignTokens.baseRadius * 0.6, accuracy: 0.001)
        XCTAssertEqual(DesignTokens.radiusLG, DesignTokens.baseRadius, accuracy: 0.001)
    }
}

/// 取色器的色相换算。
final class HueConversionTests: XCTestCase {
    func testHueOfPureRed() {
        XCTAssertEqual(RGBAColor(red: 1, green: 0, blue: 0).hue, 0, accuracy: 0.5)
    }

    func testHueOfPureGreen() {
        XCTAssertEqual(RGBAColor(red: 0, green: 1, blue: 0).hue, 120, accuracy: 0.5)
    }

    func testHueOfPureBlue() {
        XCTAssertEqual(RGBAColor(red: 0, green: 0, blue: 1).hue, 240, accuracy: 0.5)
    }

    /// 换色相保留饱和度与明度。
    func testWithHueKeepsSaturationAndBrightness() {
        let color = RGBAColor(red: 1, green: 0, blue: 0)
        let shifted = color.withHue(120)
        XCTAssertEqual(shifted.green, 1, accuracy: 0.01)
        XCTAssertEqual(shifted.red, 0, accuracy: 0.01)
        XCTAssertEqual(shifted.blue, 0, accuracy: 0.01)
    }

    func testGrayHasNoHue() {
        let gray = RGBAColor(white: 0.5)
        XCTAssertEqual(gray.hue, 0, accuracy: 0.001)
    }
}
