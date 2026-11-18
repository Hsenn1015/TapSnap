import AppKit
import SwiftUI
import TapSnapImageIO

enum EditorImageOutput: Identifiable {
    case export(CGImage)
    case combine(CGImage, CGImage)

    var id: Int { if case .export = self { return 0 }; return 1 }
}

enum ScreenshotRaster {
    enum SizeError: LocalizedError {
        case invalid
        var errorDescription: String? { "请输入有效的像素尺寸，输出画布上限为 6400 万像素。" }
    }

    private static func draw(width: Int, height: Int, _ paint: (CGContext) -> Void) throws -> CGImage {
        guard width > 0, height > 0, height <= 64_000_000 / width,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SizeError.invalid }
        ctx.interpolationQuality = .high
        paint(ctx)
        guard let image = ctx.makeImage() else { throw SizeError.invalid }
        return image
    }

    enum Axis: String, CaseIterable { case width = "宽度", height = "高度", longest = "最长边" }

    static func reference(_ image: CGImage, axis: Axis) -> Int {
        switch axis {
        case .width: return image.width
        case .height: return image.height
        case .longest: return max(image.width, image.height)
        }
    }

    static func resized(_ image: CGImage, axis: Axis, pixels: Int) throws -> CGImage {
        let original = reference(image, axis: axis)
        if pixels == original { return image }
        guard (1...64_000_000).contains(pixels) else { throw SizeError.invalid }
        let scale = Double(pixels) / Double(original)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        return try draw(width: width, height: height) { ctx in
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func combine(_ first: CGImage, _ second: CGImage, vertical: Bool) throws -> CGImage {
        let width = vertical ? max(first.width, second.width) : first.width + second.width
        let height = vertical ? first.height + second.height : max(first.height, second.height)
        return try draw(width: width, height: height) { ctx in
            ctx.draw(first, in: CGRect(x: 0, y: height - first.height, width: first.width, height: first.height))
            ctx.draw(second, in: CGRect(x: vertical ? 0 : first.width, y: vertical ? 0 : height - second.height,
                                        width: second.width, height: second.height))
        }
    }
}

struct EditorImageOutputView: View {
    @ObservedObject var controller: EditController
    let request: EditorImageOutput
    private struct Options: Hashable {
        var format: ImageFormat
        var axis = ScreenshotRaster.Axis.longest
        var pixels: String
        var vertical = false
        var swapped = false
    }
    @State private var options: Options
    @State private var completed: Options?
    @State private var preview: CGImage?
    @State private var bytes: Data?
    @State private var problem: String?

    init(controller: EditController, request: EditorImageOutput) {
        self.controller = controller
        self.request = request
        let pixels: String
        if case let .export(image) = request { pixels = String(max(image.width, image.height)) } else { pixels = "" }
        _options = State(initialValue: Options(format: ImageFormat(fileExtension: controller.environment.config.settings.capture.saveFormat) ?? .png,
                                               pixels: pixels))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch request {
            case .export(let image):
                Text("导出图片").font(.headline)
                HStack {
                    Picker("尺寸", selection: $options.axis) {
                        ForEach(ScreenshotRaster.Axis.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                    TextField("像素", text: $options.pixels).frame(width: 82)
                    Text("px")
                    Picker("格式", selection: $options.format) {
                        ForEach(ImageFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                .onChange(of: options.axis) { _, axis in options.pixels = String(ScreenshotRaster.reference(image, axis: axis)) }
            case .combine:
                Text("拼接两张图片").font(.headline)
                HStack {
                    Picker("排列", selection: $options.vertical) {
                        Text("左右").tag(false)
                        Text("上下").tag(true)
                    }.pickerStyle(.segmented)
                    Button("交换顺序") { options.swapped.toggle() }
                }
            }
            ZStack {
                if completed == options, let preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit()
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else { ProgressView() }
            }.frame(maxWidth: .infinity).frame(height: 154)
            if completed == options, let preview {
                let dimensions = "\(preview.width) × \(preview.height) px"
                Text(bytes.map { "\(dimensions) · \($0.count.formatted()) 字节" } ?? dimensions).monospacedDigit()
            }
            HStack {
                Spacer()
                Button("取消") { controller.imageOutput = nil }.keyboardShortcut(.cancelAction)
                Button(bytes == nil && request.id == 1 ? "打开合成图" : "保存…") {
                    guard completed == options, let preview else { return }
                    if let bytes {
                        guard let url = controller.environment.chooseScreenshotDestination(format: options.format) else { return }
                        do {
                            try bytes.write(to: url, options: .atomic)
                            controller.environment.toast.success("已保存到 \(url.lastPathComponent)")
                            controller.imageOutput = nil
                        } catch { problem = error.localizedDescription; NSAlert(error: error).runModal() }
                    } else { controller.editCombinedImage(preview) }
                }.keyboardShortcut(.defaultAction).disabled(completed != options)
            }
        }
        .padding(20).frame(width: 440)
        .task(id: options) { await prepare(options) }
    }

    private func prepare(_ input: Options) async {
        problem = nil
        let quality = controller.environment.config.settings.capture.jpegQuality
        do {
            try await Task.sleep(for: .milliseconds(140))
            let result = try await Task.detached(priority: .userInitiated) { [request] () -> (CGImage, Data?) in
                switch request {
                case .export(let source):
                    let image = try ScreenshotRaster.resized(source, axis: input.axis, pixels: Int(input.pixels) ?? 0)
                    return (image, try ImageCodec.encode(image, as: input.format, quality: quality))
                case .combine(let first, let second):
                    return (try ScreenshotRaster.combine(input.swapped ? second : first, input.swapped ? first : second,
                                                         vertical: input.vertical), nil)
                }
            }.value
            try Task.checkCancellation()
            preview = result.0
            bytes = result.1
            completed = input
        } catch {
            if !Task.isCancelled { completed = nil; problem = error.localizedDescription }
        }
    }
}
