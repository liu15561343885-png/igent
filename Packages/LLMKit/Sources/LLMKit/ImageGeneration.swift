import CoreKit
import Foundation

public struct ImageGenerationRequest: Sendable, Equatable {
    public var model: String
    public var prompt: String
    /// 例如 "1024x1024"。厂商支持的范围不同，留空用厂商默认。
    public var size: String?
    public var count: Int
    public var extras: [String: JSONValue]

    public init(
        model: String,
        prompt: String,
        size: String? = nil,
        count: Int = 1,
        extras: [String: JSONValue] = [:]
    ) {
        self.model = model
        self.prompt = prompt
        self.size = size
        self.count = count
        self.extras = extras
    }
}

/// 生成出来的图，还没落盘。
public struct GeneratedImage: Sendable, Equatable {
    public var data: Data
    public var mediaType: String

    public init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }
}

public enum ImageGenerationError: Error, Equatable {
    case emptyResponse
    case unsupportedShape(String)
    case downloadFailed(Int)
}

/// 图片生成适配器。
///
/// 与对话适配器分开：入参是"一句话 + 尺寸"，出参是图片字节，没有 token 也没有流式。
/// 硬塞进 `LlmAdapter` 只会让两边的协议都变脏。
public protocol ImageGenerationAdapter: Sendable {
    var profile: ProviderProfile { get }
    func generate(_ request: ImageGenerationRequest) async throws -> [GeneratedImage]
}
