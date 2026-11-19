import AppKit
import SwiftUI

struct OCRSourceLocation: Equatable {
    let rowID: UUID
    let bounds: CGRect
    private let requestID = UUID()
}

struct OCRSourcePreview: NSViewRepresentable {
    let image: CGImage
    let zoom: CGFloat
    let location: OCRSourceLocation?

    func makeNSView(context: Context) -> OCRSourceViewport { OCRSourceViewport(image: image) }

    func updateNSView(_ view: OCRSourceViewport, context: Context) {
        view.update(zoom: zoom, location: location)
    }
}

final class OCRSourceViewport: NSScrollView {
    private let artwork: SourceImageView
    private var zoom: CGFloat = 1
    private var location: OCRSourceLocation?
    private var viewportSize: CGSize = .zero

    init(image: CGImage) {
        artwork = SourceImageView(image: image)
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        documentView = artwork
        setAccessibilityLabel("识别原图")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if contentView.bounds.size != viewportSize { resizeImage() }
    }

    func update(zoom: CGFloat, location: OCRSourceLocation?) {
        let zoomChanged = self.zoom != zoom
        guard zoomChanged || self.location != location else { return }
        self.zoom = zoom
        self.location = location
        if zoomChanged { resizeImage() }
        else { revealLocation() }
    }

    private func resizeImage() {
        let size = contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        viewportSize = size
        let pixels = CGSize(width: artwork.image.width, height: artwork.image.height)
        let layout = CanvasLayout(canvas: pixels, in: size, zoom: size.width / pixels.width * zoom, fitsWidth: true)
        artwork.imageRect = CGRect(origin: layout.origin, size: layout.fitted)
        artwork.setFrameSize(CGSize(width: max(size.width, layout.fitted.width), height: max(size.height, layout.fitted.height)))
        revealLocation()
    }

    private func revealLocation() {
        let area = location.flatMap { Self.region($0.bounds, in: artwork.imageRect) }
        artwork.highlight = area
        artwork.needsDisplay = true
        if let area { artwork.scrollToVisible(area.insetBy(dx: -8, dy: -8)) }
    }

    static func region(_ normalizedBounds: CGRect, in imageRect: CGRect) -> CGRect? {
        let bounds = normalizedBounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounds.isEmpty, !imageRect.isEmpty else { return nil }
        // Vision's origin is at the bottom left; the displayed image is flipped.
        return CGRect(x: imageRect.minX + bounds.minX * imageRect.width,
                      y: imageRect.minY + (1 - bounds.maxY) * imageRect.height,
                      width: bounds.width * imageRect.width, height: bounds.height * imageRect.height)
    }
}

private final class SourceImageView: NSView {
    let image: CGImage
    var imageRect: CGRect = .zero
    var highlight: CGRect?

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        AnnotateDrawing.drawImageUpright(image, in: imageRect, context: context)
        guard let highlight else { return }
        let ink = NSColor.systemBlue
        context.setFillColor(ink.withAlphaComponent(0.15).cgColor)
        context.fill(highlight)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.stroke(highlight, width: 3)
        context.setStrokeColor(ink.cgColor)
        context.stroke(highlight, width: 1.5)
    }
}
