import CoreImage
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

    /// Finds the receipt's edges in a photo, then crops, straightens, and enhances it the way the scanner would.
    /// A photo with no clear document, such as an already tight screenshot, is kept whole.
    static func flatten(_ photo: UIImage) -> UIImage {
        guard let cgImage = photo.cgImage else { return photo }
        let image = CIImage(cgImage: cgImage).oriented(photo.cgImageOrientation)
        let request = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(ciImage: image).perform([request])
        // A small detection is more likely a label or card in the scene than the receipt.
        guard let document = request.results?.first, document.confidence > 0.5,
              document.boundingBox.width * document.boundingBox.height > 0.1 else { return render(image) ?? photo }
        let extent = image.extent
        let corner = { (point: CGPoint) in CIVector(x: extent.minX + point.x * extent.width, y: extent.minY + point.y * extent.height) }
        let flattened = image
            .applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": corner(document.topLeft), "inputTopRight": corner(document.topRight),
                "inputBottomLeft": corner(document.bottomLeft), "inputBottomRight": corner(document.bottomRight)])
            .applyingFilter("CIDocumentEnhancer")
        return render(flattened) ?? photo
    }

    private static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }

    private static func render(_ image: CIImage) -> UIImage? {
        context.createCGImage(image, from: image.extent).map { UIImage(cgImage: $0) }
    }
}
