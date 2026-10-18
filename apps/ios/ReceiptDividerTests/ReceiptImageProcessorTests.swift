import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ReceiptDivider

final class ReceiptImageProcessorTests: XCTestCase {
    /// Segmentation does not run in the simulator, so this checks the edge tracing that tightens its outline:
    /// a tilted receipt on a table with a dark wallet beside it, like the Seasons 52 photo whose corners landed on the wallet.
    func testCornersFollowTheReceiptNotWhatItLiesOn() throws {
        let size = CGSize(width: 1500, height: 2000)
        // Corners in UIKit points (origin top left).
        let corners = [CGPoint(x: 430, y: 160), CGPoint(x: 1000, y: 210), CGPoint(x: 900, y: 1860), CGPoint(x: 330, y: 1810)]
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let photo = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.45, green: 0.33, blue: 0.24, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.08, alpha: 1).setFill(); context.fill(CGRect(x: 880, y: 300, width: 520, height: 1500))
            let paper = UIBezierPath(); paper.move(to: corners[0]); corners.dropFirst().forEach(paper.addLine); paper.close()
            UIColor(white: 0.96, alpha: 1).setFill(); paper.fill()
            context.cgContext.saveGState()
            paper.addClip()
            context.cgContext.translateBy(x: 430, y: 160); context.cgContext.rotate(by: atan2(50, 570))
            let text: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 34, weight: .regular), .foregroundColor: UIColor.black]
            for line in 0..<30 { ("Item \(line)   " + String(format: "%5.2f", Double(line) * 1.37)).draw(at: CGPoint(x: 60, y: 80 + line * 52), withAttributes: text) }
            context.cgContext.restoreGState()
        }
        let image = CIImage(cgImage: try XCTUnwrap(photo.cgImage))
        let expected = corners.map { CGPoint(x: $0.x / size.width, y: 1 - $0.y / size.height) }
        // Segmentation's loose outline: the right side sits on the wallet's far edge.
        let rough = ReceiptImageProcessor.Quad(topLeft: CGPoint(x: 0.27, y: 0.93), topRight: CGPoint(x: 0.93, y: 0.89),
                                               bottomRight: CGPoint(x: 0.93, y: 0.11), bottomLeft: CGPoint(x: 0.21, y: 0.09))
        let quad = try XCTUnwrap(ReceiptImageProcessor.traced(near: rough, in: image))
        for (found, truth) in zip(quad.corners, expected) {
            XCTAssertEqual(found.x, truth.x, accuracy: 0.02, "\(quad)")
            XCTAssertEqual(found.y, truth.y, accuracy: 0.02, "\(quad)")
        }
    }

    func testScreenshotsAreNotTreatedAsCameraPhotos() throws {
        XCTAssertFalse(ReceiptImageProcessor.isCameraPhoto(try encoded(.png, exif: [:])))
        XCTAssertFalse(ReceiptImageProcessor.isCameraPhoto(try encoded(.png, exif: [kCGImagePropertyExifUserComment: "Screenshot"])))
        XCTAssertTrue(ReceiptImageProcessor.isCameraPhoto(try encoded(.jpeg, exif: [kCGImagePropertyExifExposureTime: 0.01, kCGImagePropertyExifFNumber: 1.8])))
    }

    func testScreenshotIsKeptWhole() throws {
        let data = try encoded(.png, exif: [kCGImagePropertyExifUserComment: "Screenshot"])
        let prepared = try XCTUnwrap(ReceiptImageProcessor.prepare(data))
        XCTAssertEqual(prepared.size, CGSize(width: 60, height: 120))
    }

    private func encoded(_ type: UTType, exif: [CFString: Any]) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 120), format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 120))
            UIColor.white.setFill(); context.fill(CGRect(x: 10, y: 10, width: 30, height: 80))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
