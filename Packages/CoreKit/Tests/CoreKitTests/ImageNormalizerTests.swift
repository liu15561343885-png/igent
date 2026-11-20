import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CoreKit

/// 生成测试用的位图，避免依赖外部资源文件。
private func makeImage(width: Int, height: Int, type: UTType = .png) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!

    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        output,
        type.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

final class ImageNormalizerTests: XCTestCase {
    func testLargeImageIsDownscaledPreservingAspect() throws {
        let source = makeImage(width: 3000, height: 2000)
        let normalized = try ImageNormalizer.normalize(source)

        XCTAssertEqual(max(normalized.width, normalized.height), 1568)
        XCTAssertEqual(normalized.originalWidth, 3000)
        XCTAssertEqual(normalized.originalHeight, 2000)

        // 3:2 的比例要保持住（允许取整误差）。
        let ratio = Double(normalized.width) / Double(normalized.height)
        XCTAssertEqual(ratio, 1.5, accuracy: 0.01)
    }

    /// 小图不放大：放大会白白增加字节数。
    func testSmallImageKeepsDimensions() throws {
        let source = makeImage(width: 320, height: 200)
        let normalized = try ImageNormalizer.normalize(source)

        XCTAssertEqual(normalized.width, 320)
        XCTAssertEqual(normalized.height, 200)
    }

    func testOutputIsJPEG() throws {
        let normalized = try ImageNormalizer.normalize(makeImage(width: 400, height: 400))
        XCTAssertEqual(normalized.mediaType, "image/jpeg")

        // JPEG 魔数 FF D8
        XCTAssertEqual(Array(normalized.data.prefix(2)), [0xFF, 0xD8])
    }

    func testPNGInputIsConverted() throws {
        let png = makeImage(width: 256, height: 256, type: .png)
        let normalized = try ImageNormalizer.normalize(png)
        XCTAssertNotEqual(normalized.data, png)
        XCTAssertEqual(normalized.mediaType, "image/jpeg")
    }

    func testCorruptDataThrows() {
        XCTAssertThrowsError(try ImageNormalizer.normalize(Data([0x00, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? ImageNormalizerError, .decodeFailed)
        }
    }

    func testEmptyDataThrows() {
        XCTAssertThrowsError(try ImageNormalizer.normalize(Data())) { error in
            XCTAssertEqual(error as? ImageNormalizerError, .decodeFailed)
        }
    }

    /// 自定义上限要生效。
    func testCustomMaxDimension() throws {
        let normalized = try ImageNormalizer.normalize(makeImage(width: 2000, height: 1000), maxDimension: 512)
        XCTAssertEqual(max(normalized.width, normalized.height), 512)
    }

    /// 归一化后的字节数应显著小于原始大图。
    func testFileSizeShrinks() throws {
        let source = makeImage(width: 2500, height: 2500)
        let normalized = try ImageNormalizer.normalize(source)
        XCTAssertLessThan(normalized.data.count, source.count)
    }
}
