import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageNormalizerError: Error, Equatable {
    case decodeFailed
    case encodeFailed
}

public struct NormalizedImage: Sendable, Equatable {
    public var data: Data
    public var mediaType: String
    public var width: Int
    public var height: Int
    /// 归一化前的原始像素尺寸；没有缩放时为 nil。
    public var originalWidth: Int?
    public var originalHeight: Int?

    public init(
        data: Data,
        mediaType: String,
        width: Int,
        height: Int,
        originalWidth: Int? = nil,
        originalHeight: Int? = nil
    ) {
        self.data = data
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
    }
}

/// 把任意来源的图片压成模型能接受的形态。
///
/// 三件事必须做对：
/// 1. **应用 EXIF 方向**。手机竖拍的图，像素是横的，方向存在 EXIF 里；不转正的话
///    模型看到的是躺倒的图，人却以为传对了。
/// 2. **限制长边**。三家对尺寸/字节的上限不同，1568 是都能接受的保守值。
/// 3. **统一成 JPEG**。HEIC 三家都不认，PNG 体积又太大。
public enum ImageNormalizer {
    /// 三家视觉模型都能接受的保守上限（Anthropic 推荐 1568，OpenAI 会自动切块）。
    public static let defaultMaxDimension = 1568

    public static func normalize(
        _ data: Data,
        maxDimension: Int = defaultMaxDimension,
        quality: Double = 0.82
    ) throws -> NormalizedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw ImageNormalizerError.decodeFailed
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let originalWidth = properties?[kCGImagePropertyPixelWidth] as? Int
        let originalHeight = properties?[kCGImagePropertyPixelHeight] as? Int

        // 只缩小不放大：maxPixelSize 是上界。
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageNormalizerError.decodeFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageNormalizerError.encodeFailed
        }

        let encodeOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageNormalizerError.encodeFailed
        }

        // 注意：`UTType.identifier` 是 "public.jpeg"，厂商要的是 MIME "image/jpeg"。
        let mimeType = UTType.jpeg.preferredMIMEType ?? "image/jpeg"
        let scaled = originalWidth != nil && originalHeight != nil
        return NormalizedImage(
            data: output as Data,
            mediaType: mimeType,
            width: image.width,
            height: image.height,
            originalWidth: scaled ? originalWidth : nil,
            originalHeight: scaled ? originalHeight : nil
        )
    }
}
