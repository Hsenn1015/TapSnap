import AppKit
import Foundation
import TapSnapCore
import TapSnapOCR
import TapSnapScreen

/// 文字识别的入口。
///
/// 用 Vision 识别截图里的文字，在结果窗口中可选择、复制或翻译。
final class OCRCoordinator {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// 框选区域后识别。
    func captureAndRecognize() {
        environment.captureCoordinator.start(.ocr)
        environment.toast.info("框选需要识别的区域")
    }

    /// 直接识别整屏（菜单「全屏文字识别」）。
    func recognizeFullScreen() {
        Task { @MainActor in
            do {
                let frames = try await environment.capture.captureAllScreens(options: .init(
                    excludedWindowIDs: environment.toastPresenter.windowID.map { [$0] } ?? []
                ))
                guard let frame = frames.first(where: { $0.screen.isMain }) ?? frames.first else {
                    environment.toast.error("没有可识别的屏幕")
                    return
                }
                try await run(frame.image)
            } catch {
                let capture = PendingScreenCapture(outcome: .ocr, mode: .fullScreen)
                guard !environment.guideScreenCapturePermission(for: error, resuming: capture) else { return }
                environment.toast.error("识别失败：\(error.localizedDescription)")
            }
        }
    }

    /// 识别一张现成的图（截图流程已经拿到裁剪结果时用）。
    func recognize(_ image: CGImage) {
        Task { @MainActor in
            do {
                try await run(image)
            } catch {
                environment.toast.error("识别失败：\(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func run(_ image: CGImage) async throws {
        let settings = environment.config.settings.ocr
        let options = OCRService.Options(languages: settings.languages)
        let result = try await environment.ocr.recognize(image, options: options)

        guard !result.isEmpty else {
            environment.toast.warning("没有识别到文字")
            return
        }

        if settings.autoCopyText {
            let text = OCRResultDisplayMode.paragraphs.copyText(in: result)
            environment.pinTransfer.copy(text)
            environment.toast.success("已复制 \(text.count) 个字符")
        }

        environment.ocrResultPanel.show(document: result, image: image, markdownSource: { [ocr = environment.ocr] in
            let tables = await ocr.recognizeTables(in: result, image: image)
            return await Task.detached(priority: .userInitiated) {
                OCRMarkdown.source(from: result, tables: tables)
            }.value
        }, onTranslate: { [environment] in
            environment.translateImage(image, document: result)
        }) { [environment] text in
            environment.pinTransfer.copy(text)
            environment.toast.success("已复制 \(text.count) 个字符")
        }
    }
}

/// 表格识别。
///
/// 用截图网格和 OCR 位置恢复行列，再转为 CSV。
final class TableRecognizer {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func captureAndRecognize() {
        environment.captureCoordinator.start(.table)
        environment.toast.info("框选表格区域")
    }

    /// 截图流程拿到区域图后进入识别。
    func recognize(_ image: CGImage) {
        Task { @MainActor in
            do {
                let table = try await extract(image)
                guard !table.rows.isEmpty else {
                    environment.toast.warning("没有识别到表格内容")
                    return
                }
                environment.pinTransfer.copy(table.csv)
                environment.toast.success("表格已识别（\(table.rows.count) 行），CSV 已复制")
            } catch TableRecognitionError.noTableDetected {
                environment.toast.warning("没有识别到完整的表格，请把表头和数据行一起框选")
            } catch {
                environment.toast.error("表格识别失败：\(error)")
            }
        }
    }

    func extract(_ image: CGImage) async throws -> TableData {
        let languages = environment.config.settings.ocr.languages
        let document = try await environment.ocr.recognize(image, options: .init(languages: languages, recognizeParagraphs: false))
        let tables = await environment.ocr.recognizeTables(in: document, image: image)
        guard let table = tables.max(by: { $0.lineIDs.count < $1.lineIDs.count }) else {
            throw TableRecognitionError.noTableDetected
        }
        return TableData(rows: table.rows)
    }
}

enum TableRecognitionError: Error {
    case noTableDetected
}

/// 识别出的表格。
struct TableData: Sendable {
    var rows: [[String]]

    var csv: String {
        rows.map { $0.map(Self.escape).joined(separator: ",") }.joined(separator: "\n")
    }

    private static func escape(_ field: String) -> String {
        field.contains(",") || field.contains("\"") || field.contains(where: \.isNewline)
            ? "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
            : field
    }
}
