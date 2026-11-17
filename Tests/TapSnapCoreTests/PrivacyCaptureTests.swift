import AppKit
import CoreImage
import CoreText
import TapSnapConfig
import TapSnapCore
import TapSnapImageIO
import TapSnapPrivacy
import XCTest
@testable import TapSnapApp

@MainActor
final class PrivacyCaptureTests: XCTestCase {
    private func textImage(width: Int = 720, height: Int = 160, fontSize: CGFloat = 28, rows: [(String, Int, Int)]) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (text, x, y) in rows {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: x, y: height - y)
            CTLineDraw(line, context)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func awaitScan(_ privacy: PrivacyEditing) async throws {
        for _ in 0..<300 {
            if !privacy.blocksOutput { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The local scan did not complete")
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 4)])
    }

    func testOnDeviceScanFindsOriginalPixelLocationsInLongImage() async throws {
        let image = try textImage(height: 4100, rows: [
            ("Email: sample@example.invalid", 36, 100),
            ("Email: second@example.invalid", 36, 1935),
            ("Email: final@example.invalid", 36, 3940)
        ])
        let findings = try await PrivacyScanner.scan(image, settings: PrivacySettings())
        let emails = findings.filter { $0.label == PrivacyRule.email.title }
        XCTAssertEqual(emails.count, 3, "The overlapping tile should not add a second copy of the same finding")
        XCTAssertTrue(emails.allSatisfy(\.isCovered))
        XCTAssertEqual(emails.count, emails.filter { $0.bounds.minX >= 0 && $0.bounds.maxX <= 720 }.count)
        let result = try PrivacyMask.flattened(image, covering: emails.map(\.bounds))
        for (email, y) in zip(emails, [100, 1935, 3940]) {
            XCTAssertGreaterThan(email.bounds.minY, CGFloat(y - 50))
            XCTAssertLessThan(email.bounds.minY, CGFloat(y))
            XCTAssertEqual(try pixel(result, x: Int(email.bounds.midX), y: Int(email.bounds.midY)), [0, 0, 0, 255])
        }
        XCTAssertEqual(try pixel(result, x: 10, y: 10), [255, 255, 255, 255])
    }

    func testQRCodeCanBeCoveredWithoutReturningItsContents() async throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://example.invalid/synthetic".utf8), forKey: "inputMessage")
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let code = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
        let context = try XCTUnwrap(CGContext(data: nil, width: 350, height: 350, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 350, height: 350))
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: 44, y: 50, width: code.width, height: code.height))
        let image = try XCTUnwrap(context.makeImage())
        var settings = PrivacySettings()
        for rule in PrivacyRule.allCases { settings[rule] = .off }
        settings[.barcode] = .automatic
        let findings = try await PrivacyScanner.scan(image, settings: settings)
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.label, PrivacyRule.barcode.title)
        XCTAssertTrue(finding.isCovered)
        let result = try PrivacyMask.flattened(image, covering: [finding.bounds])
        let secondScan = try await PrivacyScanner.scan(result, settings: settings)
        XCTAssertTrue(secondScan.isEmpty, "A covered code should not be decodable")
    }

    func testEditorOutputsAfterScanAndMasksEffectSamples() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let config = ConfigStore(fileURL: temp.appendingPathComponent("settings.json"))
        let image = try textImage(width: 240, height: 140, rows: [])
        let editor = EditController(environment: AppEnvironment(config: config), image: image, scale: 2,
                                    style: EditItemStyle())
        editor.scanPrivacy()
        XCTAssertNil(editor.renderedImage(), "Even an immediate output cannot bypass an in-flight scan")
        try await awaitScan(editor.privacy)
        XCTAssertEqual(editor.privacy.phase, .ready)
        XCTAssertNotNil(editor.renderedImage())

        let mask = PrivacyMaskItem(bounds: CGRect(x: 43, y: 23, width: 34, height: 24),
                                   appearance: .init(style: .solid, rgb: 0))
        editor.add(mask)
        editor.add(MagnifierItem(bounds: CGRect(x: 12, y: 7, width: 96, height: 56), zoom: 2))
        let rendered = try XCTUnwrap(editor.renderedImage())
        XCTAssertEqual(try pixel(rendered, x: 120, y: 70), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(rendered, x: 120, y: 41), [0, 0, 0, 255],
                       "A magnifier cannot reproduce the original unmasked pixels")
        XCTAssertEqual(try pixel(rendered, x: 5, y: 5), [255, 255, 255, 255])
        editor.remove(mask)
        let edited = try XCTUnwrap(editor.renderedImage())
        XCTAssertEqual(try pixel(edited, x: 120, y: 70), [255, 255, 255, 255])
    }

    func testScanCreatesEditableMasksAndSuggestionsAndRescanPreservesEdits() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let config = ConfigStore(fileURL: temp.appendingPathComponent("settings.json"))
        config.update { $0.privacy[.email] = .review }
        let image = try textImage(rows: [("Email: sample@example.invalid", 36, 60),
                                         ("Mobile: 13900000000", 36, 120)])
        let editor = EditController(environment: AppEnvironment(config: config), image: image, scale: 2,
                                    style: EditItemStyle())
        editor.scanPrivacy()
        try await awaitScan(editor.privacy)
        let mobile = try XCTUnwrap(editor.document.items.first as? PrivacyMaskItem)
        let suggestion = try XCTUnwrap(editor.privacy.suggestions.first)
        XCTAssertEqual(suggestion.label, PrivacyRule.email.title)
        XCTAssertEqual(editor.document.items.count, 1)
        XCTAssertTrue(editor.canUndo)
        XCTAssertNotNil(editor.renderedImage())

        editor.applyPrivacySuggestion(suggestion.id)
        XCTAssertTrue(editor.privacy.suggestions.isEmpty)
        XCTAssertEqual(editor.document.items.count, 2)
        mobile.bounds = mobile.bounds.offsetBy(dx: 0, dy: -8)
        let moved = mobile.bounds
        editor.scanPrivacy()
        try await awaitScan(editor.privacy)
        XCTAssertEqual(editor.document.items.count, 2)
        XCTAssertEqual(mobile.bounds, moved)
        editor.remove(mobile)
        editor.scanPrivacy()
        try await awaitScan(editor.privacy)
        XCTAssertEqual(editor.document.items.count, 1)
    }

    func testPrivacyReviewBlocksUncoveredFindingsAndAllowsRedactedPixels() throws {
        let image = try textImage(width: 240, height: 140, rows: [])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let config = ConfigStore(fileURL: temp.appendingPathComponent("settings.json"))
        config.update {
            $0.capture.saveDirectory = temp.path
            $0.capture.autoCopyToClipboard = false
            $0.capture.autoSaveToFile = true
            $0.privacy.appearance = .init(style: .solid, rgb: 0)
        }
        let editor = EditController(environment: AppEnvironment(config: config), image: image, scale: 2,
                                    style: EditItemStyle(), requiresPrivacyReview: true)
        let finding = PrivacyFinding(label: "邮箱", bounds: CGRect(x: 40, y: 30, width: 40, height: 20), isCovered: false)
        editor.privacy.receive([finding], refreshingSuggestions: true) { _ in }
        XCTAssertNil(editor.renderedImage())
        editor.perform(.save)
        editor.perform(.confirm)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temp.path).contains { $0.hasSuffix(".png") })

        editor.applyAllPrivacySuggestions()
        XCTAssertTrue(editor.privacySuggestions.isEmpty)
        let redacted = try XCTUnwrap(editor.renderedImage())
        XCTAssertEqual(try pixel(redacted, x: 50, y: 40), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(redacted, x: 5, y: 5), [255, 255, 255, 255])

        let mask = try XCTUnwrap(editor.document.items.first as? PrivacyMaskItem)
        mask.bounds.origin.x += 10
        XCTAssertNil(editor.renderedImage(), "A partially moved mask cannot clear the finding")
        editor.remove(mask)
        XCTAssertEqual(editor.privacySuggestions, [finding])
        editor.updateCropRect(CGRect(x: 45, y: 10, width: 60, height: 30))
        XCTAssertEqual(editor.renderedImage()?.width, 120, "A finding outside the exported crop needs no mask")
        editor.updateCropRect(nil)
        editor.applyAllPrivacySuggestions()
        editor.perform(.undo)
        XCTAssertNil(editor.renderedImage(), "Undoing the mask must restore the review requirement")
    }

    func testPrivacyReviewHonorsExplicitIgnoreWithoutHidingOtherFindings() throws {
        let image = try textImage(width: 240, height: 140, rows: [])
        let editor = EditController(environment: AppEnvironment(), image: image, scale: 1,
                                    style: EditItemStyle(), requiresPrivacyReview: true)
        let name = PrivacyFinding(label: "姓名", bounds: CGRect(x: 30, y: 20, width: 35, height: 16), isCovered: false)
        let phone = PrivacyFinding(label: "号码", bounds: CGRect(x: 80, y: 20, width: 90, height: 18), isCovered: false)
        editor.privacy.receive([name, phone], refreshingSuggestions: true) { _ in }
        editor.privacy.markHandled([name], ignoring: true)
        XCTAssertEqual(editor.privacySuggestions, [phone])
        XCTAssertNil(editor.renderedImage())
        editor.applyPrivacySuggestion(phone.id)
        XCTAssertNotNil(editor.renderedImage())
    }

    func testPrivacyReviewCanInspectThenSaveAllMasksFromAlert() async throws {
        _ = NSApplication.shared
        let image = try textImage(width: 720, height: 220, rows: [
            ("Email: sample@example.invalid", 36, 60), ("Email: second@example.invalid", 36, 165)
        ])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let config = ConfigStore(fileURL: temp.appendingPathComponent("settings.json"))
        config.update {
            $0.capture.saveDirectory = temp.path
            $0.capture.saveFormat = "png"
            $0.privacy[.email] = .review
            $0.privacy.appearance = .init(style: .solid, rgb: 0)
        }
        let editor = EditController(environment: AppEnvironment(config: config), image: image, scale: 1,
                                    style: EditItemStyle(), requiresPrivacyReview: true)
        editor.present()
        defer { editor.close() }
        try await awaitScan(editor.privacy)
        XCTAssertEqual(editor.privacy.phase, .ready)
        let findings = editor.privacySuggestions
        XCTAssertEqual(findings.count, 2)

        func selectAlertButton(_ title: String) {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                func button(in view: NSView) -> NSButton? {
                    if let button = view as? NSButton, button.title == title { return button }
                    return view.subviews.lazy.compactMap { button(in: $0) }.first
                }
                if let root = NSApp.modalWindow?.contentView, let action = button(in: root) {
                    action.performClick(nil)
                } else {
                    XCTFail("没有找到隐私提示中的「\(title)」")
                    NSApp.abortModal()
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
        }

        selectAlertButton("逐处检查")
        editor.perform(.save)
        XCTAssertTrue(editor.privacy.showsSuggestions)
        XCTAssertEqual(editor.privacySuggestions, findings)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temp.path).allSatisfy { !$0.hasSuffix(".png") })

        editor.privacy.showsSuggestions = false
        selectAlertButton("全部打码并保存")
        editor.perform(.save)
        XCTAssertTrue(editor.privacySuggestions.isEmpty)
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "png" })
        let saved = try ImageCodec.decode(Data(contentsOf: url))
        let bitmap = NSBitmapImageRep(cgImage: saved)
        for finding in findings {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(finding.bounds.midX), y: Int(finding.bounds.midY))?
                .usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, 0, accuracy: 0.01)
        }
    }

    func testFailedScanKeepsManualMasksAndAllowsOutput() async throws {
        let image = try textImage(rows: [])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let config = ConfigStore(fileURL: temp.appendingPathComponent("settings.json"))
        var broken = CustomPrivacyRule()
        broken.name = "无效样本"
        broken.pattern = "["
        config.update { $0.privacy.customRules = [broken] }
        let editor = EditController(environment: AppEnvironment(config: config), image: image, scale: 1,
                                    style: EditItemStyle())
        editor.add(PrivacyMaskItem(bounds: CGRect(x: 15, y: 15, width: 30, height: 20), appearance: .init()))
        editor.scanPrivacy()
        try await awaitScan(editor.privacy)
        XCTAssertEqual(editor.privacy.phase, .failed)
        XCTAssertFalse(editor.privacy.blocksOutput)
        XCTAssertEqual(editor.document.items.count, 1)
        XCTAssertNotNil(editor.renderedImage())
    }

    func testEachPrivacyStyleFullyReplacesPixelsIndependentlyOfSource() throws {
        let source = try XCTUnwrap(CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let clear = try XCTUnwrap(source.makeImage())
        let bounds = CGRect(x: 5.15, y: 13.9, width: 70.05, height: 17.35)
        let neighbor = CGRect(x: 23, y: 9, width: 20, height: 4)
        source.setFillColor(CGColor(red: 1, green: 0, blue: 0.4, alpha: 1))
        source.fill([CGRect(x: 10, y: 37, width: 141, height: 36),
                     CGRect(x: 46, y: 74, width: 40, height: 8)])
        let sensitive = try XCTUnwrap(source.makeImage())
        for style in PrivacyMaskStyle.allCases {
            func render(_ image: CGImage) throws -> CGImage {
                let document = EditDocument(baseImage: image, scale: 2)
                for rect in [bounds, neighbor] {
                    document.append(PrivacyMaskItem(bounds: rect, appearance: .init(style: style)))
                }
                return try document.render()
            }
            let first = try render(clear)
            let second = try render(sensitive)
            XCTAssertEqual(first.dataProvider?.data as Data?, second.dataProvider?.data as Data?, style.title)
            XCTAssertEqual(try pixel(second, x: 10, y: 27).last, 255, style.title)
            XCTAssertEqual(try pixel(second, x: 150, y: 62).last, 255, style.title)
            XCTAssertEqual(try pixel(second, x: 2, y: 2), [0, 0, 0, 0])
        }
    }

    func testMaskRoundsAndFeathersOutsideAnOpaquePixelAlignedCore() throws {
        let image = try textImage(width: 160, height: 100, rows: [])
        let document = EditDocument(baseImage: image, scale: 2)
        document.append(PrivacyMaskItem(bounds: CGRect(x: 15.25, y: 15.25, width: 50, height: 12.5),
                                        appearance: .init(style: .solid, rgb: 0)))
        let rendered = try document.render()
        let nearEdge = try pixel(rendered, x: 80, y: 28)
        let farEdge = try pixel(rendered, x: 80, y: 22)
        XCTAssertEqual(try pixel(rendered, x: 30, y: 30), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(rendered, x: 130, y: 55), [0, 0, 0, 255])
        XCTAssertGreaterThan(nearEdge[0], 0)
        XCTAssertLessThan(nearEdge[0], farEdge[0])
        XCTAssertLessThan(farEdge[0], 255)
        XCTAssertEqual(try pixel(rendered, x: 22, y: 22), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(rendered, x: 80, y: 18), [255, 255, 255, 255])
    }

    func testMaskedKeysInSmallTableRowsCoverEntireValueAtOriginalPosition() async throws {
        let image = try textImage(width: 1154, height: 943, fontSize: 14, rows: [
            ("API keys", 118, 50),
            ("API keys are only shown in full after creation.", 118, 86),
            ("Name", 136, 245), ("Tracking ID", 365, 245), ("Key", 605, 245), ("Created", 761, 245),
            ("Demo record", 136, 295), ("demo-0000 ... 9999", 365, 295), ("sk-demo1*****ABCD", 605, 295),
            ("2026-02-03", 761, 295),
            ("Sample", 136, 398), ("Managed by the app", 605, 398),
            ("Another record", 136, 449), ("sk-demo2 ••••• WXYZ", 605, 449), ("2026-02-05", 761, 449)
        ])
        let result = try await PrivacyScanner.scan(image, settings: PrivacySettings())
        let tokens = result.filter { $0.label == PrivacyRule.token.title }
        XCTAssertEqual(tokens.count, 2)
        XCTAssertTrue(tokens.allSatisfy(\.isCovered))
        XCTAssertTrue(tokens.allSatisfy { $0.bounds.maxX < 765 })
        for (token, baseline) in zip(tokens, [295, 449]) {
            XCTAssertLessThanOrEqual(token.bounds.minX, 605)
            XCTAssertGreaterThan(token.bounds.maxX, 719)
            XCTAssertGreaterThan(token.bounds.minY, CGFloat(baseline - 25))
            XCTAssertGreaterThanOrEqual(token.bounds.maxY, CGFloat(baseline + 1))
        }
    }

    func testLegacyMosaicDefaultMigratesOnceAndCanBeSelectedAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        var original = Settings.withDefaultShortcuts()
        original.schemaVersion = 4
        original.privacy.appearance = .init(style: .mosaic, patternSize: 12)
        original.privacy.ai = PrivacyAIConfiguration(provider: .deepSeek)
        let storage = LocalStore<Settings>(fileURL: file)
        try storage.save(original)

        let config = ConfigStore(fileURL: file)
        XCTAssertEqual(config.settings.privacy.appearance.style, .frosted)
        XCTAssertEqual(config.settings.privacy.appearance.patternSize, 12)
        XCTAssertEqual(config.settings.privacy.ai, original.privacy.ai)
        XCTAssertEqual(config.settings.shortcuts, original.shortcuts)
        config.update { $0.privacy.appearance.style = .mosaic }
        XCTAssertEqual(ConfigStore(fileURL: file).settings.privacy.appearance.style, .mosaic)
    }

    func testPrivacySettingsRoundTripAndOldSettingsKeepShortcuts() throws {
        var original = Settings.withDefaultShortcuts()
        original.capture.autoSaveToFile = true
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        oldJSON.removeValue(forKey: "privacyRules")
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertFalse(decoded.privacy.enabled)
        XCTAssertEqual(decoded.shortcuts, original.shortcuts)
        XCTAssertTrue(decoded.capture.autoSaveToFile)

        original.privacy.enabled = true
        original.privacy[.face] = .automatic
        original.privacy[.mobile] = .off
        original.privacy.internalDomains = "corp.example"
        var rule = CustomPrivacyRule()
        rule.name = "内部工单"
        rule.pattern = #"INT-\d{4}"#
        original.privacy.customRules = [rule]
        let legacyPrivacy = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(legacyPrivacy.privacy.appearance.style, .frosted)
        XCTAssertNil(legacyPrivacy.privacy.ai)
        original.privacy.appearance = .init(style: .stripes, patternSize: 16, rgb: 0x667788)
        original.privacy.ai = PrivacyAIConfiguration(provider: .qwen)
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
    }

}
