import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import DisplayMonitor

final class GifFrameSamplingTests: XCTestCase {
    func testThirtySecondsAtThirtyFPSUsesWholeClipWithinThreeHundredFrames() throws {
        let plan = try GifFrameSamplingPlan(startSeconds: 5, duration: 30, frameRate: 30)
        XCTAssertEqual(plan.frameCount, 300)
        XCTAssertEqual(plan.sampleTimes.first, 5)
        XCTAssertEqual(try XCTUnwrap(plan.sampleTimes.last), 34.9, accuracy: 0.000_001)
        XCTAssertEqual(plan.durationSeconds, 30, accuracy: 0.000_001)
        XCTAssertTrue(plan.frameDelays.allSatisfy { abs($0 - 0.1) < 0.000_001 })
    }

    func testLowFrameCapStillDistributesSamplesAcrossEntireClip() throws {
        let plan = try GifFrameSamplingPlan(startSeconds: 12, duration: 30, frameRate: 30, maximumFrames: 3)
        XCTAssertEqual(plan.sampleTimes, [12, 22, 32])
        XCTAssertEqual(plan.frameDelays, [10, 10, 10])
        XCTAssertEqual(plan.durationSeconds, 30)
    }

    func testNonIntegralClipUsesPositiveCentisecondDelaysAndActualQuantizedDuration() throws {
        let plan = try GifFrameSamplingPlan(startSeconds: 0, duration: 1.234, frameRate: 30)
        XCTAssertEqual(plan.frameCount, 38)
        XCTAssertTrue(plan.frameDelays.allSatisfy { $0 >= 0.01 })
        XCTAssertEqual(plan.durationSeconds, 1.23, accuracy: 0.000_001)
        XCTAssertLessThan(try XCTUnwrap(plan.sampleTimes.last), 1.234)
        let tiny = try GifFrameSamplingPlan(startSeconds: 0, duration: 0.001, frameRate: 30)
        XCTAssertEqual(tiny.frameCount, 1)
        XCTAssertEqual(tiny.durationSeconds, 0.01)
    }

    func testInvalidFiniteAndBoundaryInputsAreRejectedWithoutIntegerConversionTraps() throws {
        for duration in [Double.nan, .infinity, -.infinity, -1, 0, 30.01] {
            XCTAssertThrowsError(try GifFrameSamplingPlan(startSeconds: 0, duration: duration, frameRate: 30))
        }
        for rate in [Double.nan, .infinity, -.infinity, -1, 0, 30.01] {
            XCTAssertThrowsError(try GifFrameSamplingPlan(startSeconds: 0, duration: 30, frameRate: rate))
        }
        for start in [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(try GifFrameSamplingPlan(startSeconds: start, duration: 1, frameRate: 10))
        }
        XCTAssertThrowsError(try GifFrameSamplingPlan(startSeconds: 0, duration: 1, frameRate: 10, maximumFrames: 0))
        for total in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertThrowsError(try GifExportOptions().resolve(totalDuration: total))
        }
        XCTAssertThrowsError(try GifExportOptions(startSeconds: .nan).resolve(totalDuration: 30))
        XCTAssertThrowsError(try GifExportOptions(endSeconds: .infinity).resolve(totalDuration: 30))
        XCTAssertThrowsError(try GifExportOptions(frameRate: .nan).resolve(totalDuration: 30))
        XCTAssertThrowsError(try GifExportOptions(maximumWidth: 159).resolve(totalDuration: 30))
        XCTAssertThrowsError(try GifExportOptions(startSeconds: 30).resolve(totalDuration: 30))
        let clipped = try GifExportOptions(startSeconds: 10, endSeconds: 100).resolve(totalDuration: 100)
        XCTAssertEqual(clipped.startSeconds, 10)
        XCTAssertEqual(clipped.durationSeconds, 30)
    }

    func testEncodedThirtySecondGIFIncludesLateClipFramesAndMatchesDelaySum() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gif-sampling-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("test.gif")
        let plan = try GifFrameSamplingPlan(startSeconds: 0, duration: 30, frameRate: 30)
        let first = try solidImage(red: 1, blue: 0)
        let last = try solidImage(red: 0, blue: 1)
        var sampledTimes: [Double] = []
        let result = try GifRenderer.encode(destinationURL: output, plan: plan) { seconds in
            sampledTimes.append(seconds)
            return seconds < 20 ? first : last
        }
        XCTAssertEqual(result.frameCount, 300)
        XCTAssertEqual(result.durationSeconds, 30, accuracy: 0.000_001)
        XCTAssertGreaterThan(try XCTUnwrap(sampledTimes.last), 29)
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(encoded), 300)
        var duration = 0.0
        for index in 0..<300 {
            let properties = CGImageSourceCopyPropertiesAtIndex(encoded, index, nil) as? [CFString: Any]
            let gif = try XCTUnwrap(properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            duration += try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber).doubleValue
        }
        XCTAssertEqual(duration, result.durationSeconds, accuracy: 0.000_001)
        let lastFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 299, nil))
        XCTAssertGreaterThan(try blueComponent(of: lastFrame), 240)
    }

    func testFailedEncodingRemovesOnlyTemporaryGIFAndKeepsSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gif-failure-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let original = Data("source sentinel".utf8)
        try original.write(to: source)
        let output = root.appendingPathComponent("test.gif")
        let plan = try GifFrameSamplingPlan(startSeconds: 0, duration: 1, frameRate: 10)
        var count = 0
        XCTAssertThrowsError(try GifRenderer.encode(destinationURL: output, plan: plan) { _ in
            count += 1
            if count > 2 { throw CocoaError(.fileReadCorruptFile) }
            return try solidImage(red: 1, blue: 0)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func solidImage(red: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try XCTUnwrap(context.makeImage())
    }

    private func blueComponent(of image: CGImage) throws -> UInt8 {
        var rgba = [UInt8](repeating: 0, count: 4)
        let blue = rgba.withUnsafeMutableBytes { bytes -> UInt8? in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return bytes[2]
        }
        return try XCTUnwrap(blue)
    }
}
