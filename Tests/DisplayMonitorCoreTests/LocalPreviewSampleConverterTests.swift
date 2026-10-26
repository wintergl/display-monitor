import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import DisplayMonitor

@MainActor
final class LocalPreviewSampleConverterTests: XCTestCase {
    func testRegionRecordingKeepsCropAndOutputGeometryInLocalScreenshotConfiguration() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Dedicated screenshot configuration requires macOS26") }
        let input = SCStreamConfiguration()
        input.width = 1120
        input.height = 640
        input.sourceRect = CGRect(x: 440, y: 400, width: 560, height: 320)
        input.showsCursor = false
        let output = LocalPreviewScreenshotSource.screenshotConfiguration(from: input)
        XCTAssertEqual(output.sourceRect, input.sourceRect)
        XCTAssertEqual(output.width, 1120)
        XCTAssertEqual(output.height, 640)
        XCTAssertFalse(output.showsCursor)
        XCTAssertEqual(output.displayIntent, .local)
        XCTAssertEqual(output.dynamicRange, .sdr)
        XCTAssertNil(output.fileURL)
    }
    func testScreenshotPixelsBecomeReadyBGRAPreviewFrame() throws {
        let converter = try LocalPreviewSampleConverter(width: 4, height: 2)
        let image = try solidImage(width: 4, height: 2)
        let sample = try converter.sample(from: image)
        XCTAssertTrue(CMSampleBufferDataIsReady(sample))
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 4)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 2)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pixel = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThan(pixel[0], 3)
        XCTAssertLessThan(pixel[1], 3)
        XCTAssertGreaterThan(pixel[2], 250)
        XCTAssertEqual(pixel[3], 255)
    }

    func testInvalidSizeOrUnexpectedImageCannotReachPreview() throws {
        XCTAssertThrowsError(try LocalPreviewSampleConverter(width: 0, height: 2))
        let converter = try LocalPreviewSampleConverter(width: 4, height: 2)
        XCTAssertThrowsError(try converter.sample(from: solidImage(width: 2, height: 4)))
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  components: [1, 0, 0, 1])))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
