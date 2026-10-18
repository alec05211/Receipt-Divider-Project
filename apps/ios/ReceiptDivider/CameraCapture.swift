import CoreImage
import ImageIO
import SwiftUI
import UIKit
import Vision
import VisionKit

/// Apple's document scanner (the one in Notes), which finds, flattens, and cleans up the receipt itself.
struct DocumentScanner: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var image: UIImage?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController(); scanner.delegate = context.coordinator; return scanner
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner; init(_ parent: DocumentScanner) { self.parent = parent }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // A long receipt may be scanned as several pages; they are stitched into one image.
            parent.image = ReceiptImageProcessor.combine((0..<scan.pageCount).map(scan.imageOfPage)); parent.dismiss()
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.dismiss() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.dismiss() }
    }
}

/// Produces the one receipt image that is both parsed and stored: upright, cropped to the receipt, and flattened.
/// Library photos go through the same building blocks the scanner uses, since the scanner only accepts live camera input.
enum ReceiptImageProcessor {
    private static let context = CIContext()

    /// Stitches scanned pages top to bottom at the width of the widest page.
    static func combine(_ pages: [UIImage]) -> UIImage? {
        guard pages.count > 1 else { return pages.first.map(upright) }
        let width = pages.map(\.size.width).max() ?? 0
        let heights = pages.map { $0.size.height * width / $0.size.width }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: heights.reduce(0, +)), format: format).image { _ in
            var y: CGFloat = 0
            for (page, height) in zip(pages, heights) { page.draw(in: CGRect(x: 0, y: y, width: width, height: height)); y += height }
        }
    }

    /// Prepares a library image: a camera photo is flattened, while a screenshot or other non-camera image is kept whole,
    /// since it is already square to the screen and a detected "document" inside it would only skew it.
    static func prepare(_ data: Data) -> UIImage? {
        guard let picture = UIImage(data: data) else { return nil }
        return isCameraPhoto(data) ? flatten(picture) : upright(picture)
    }

    /// A screenshot is tagged as one in its EXIF comment; any image without camera exposure data was not taken by a camera.
    static func isCameraPhoto(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if (exif[kCGImagePropertyExifUserComment] as? String)?.localizedCaseInsensitiveContains("screenshot") == true { return false }
        return exif[kCGImagePropertyExifExposureTime] != nil || exif[kCGImagePropertyExifFNumber] != nil
    }

    /// Finds the receipt's edges in a photo, then crops, straightens, and enhances it the way the scanner would.
    /// A photo with no clear document is kept whole.
    static func flatten(_ photo: UIImage) -> UIImage {
        guard let cgImage = photo.cgImage else { return photo }
        let image = CIImage(cgImage: cgImage).oriented(photo.cgImageOrientation)
        guard let quad = documentQuad(in: image) else { return render(image) ?? photo }
        let extent = image.extent
        let corner = { (point: CGPoint) in CIVector(x: extent.minX + point.x * extent.width, y: extent.minY + point.y * extent.height) }
        let flattened = image
            .applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": corner(quad.topLeft), "inputTopRight": corner(quad.topRight),
                "inputBottomLeft": corner(quad.bottomLeft), "inputBottomRight": corner(quad.bottomRight)])
            .applyingFilter("CIDocumentEnhancer")
        return render(flattened) ?? photo
    }

    /// The receipt's corners, normalized with the origin at the bottom left.
    struct Quad: Equatable {
        var topLeft, topRight, bottomRight, bottomLeft: CGPoint
        var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }
        var bounds: CGRect {
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
            (self.topLeft, self.topRight, self.bottomRight, self.bottomLeft) = (topLeft, topRight, bottomRight, bottomLeft)
        }
        init(_ observation: VNRectangleObservation) {
            self.init(topLeft: observation.topLeft, topRight: observation.topRight,
                      bottomRight: observation.bottomRight, bottomLeft: observation.bottomLeft)
        }
    }

    /// Document segmentation finds roughly where the receipt is but places its corners loosely, often on whatever the
    /// receipt lies on. The paper's straight edges are then traced near that outline, and the traced corners win when they agree.
    static func documentQuad(in image: CIImage) -> Quad? {
        let segmentation = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(ciImage: image).perform([segmentation])
        // A small detection is more likely a label or card in the scene than the receipt.
        guard let document = segmentation.results?.first, document.confidence > 0.5,
              document.boundingBox.width * document.boundingBox.height > 0.1 else { return nil }
        let rough = Quad(document)
        return traced(near: rough, in: image) ?? rough
    }

    /// The largest straight-edged quad that lies within the rough outline and fills a good share of it.
    static func traced(near rough: Quad, in image: CIImage) -> Quad? {
        let region = rough.bounds.insetBy(dx: -0.08, dy: -0.08).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rectangles = VNDetectRectanglesRequest()
        rectangles.regionOfInterest = region
        rectangles.minimumAspectRatio = 0.05
        rectangles.maximumAspectRatio = 1
        rectangles.minimumSize = 0.3
        rectangles.quadratureTolerance = 25
        rectangles.minimumConfidence = 0.5
        rectangles.maximumObservations = 8
        try? VNImageRequestHandler(ciImage: image).perform([rectangles])
        // Rectangle results come back normalized to the whole image, not the region of interest.
        let candidates = (rectangles.results ?? []).map(Quad.init).filter { candidate in
            let shared = candidate.bounds.intersection(rough.bounds)
            return !shared.isNull && area(shared) > 0.85 * area(candidate.bounds) && area(shared) > 0.4 * area(rough.bounds)
        }
        return candidates.max { area($0.bounds) < area($1.bounds) }
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }

    private static func render(_ image: CIImage) -> UIImage? {
        context.createCGImage(image, from: image.extent).map { UIImage(cgImage: $0) }
    }
}
