import CoreKit
import Foundation

/// 已解析的图片负载：MIME + base64。
public struct ResolvedImage: Sendable, Equatable {
    public var mediaType: String
    public var base64: String

    public init(mediaType: String, base64: String) {
        self.mediaType = mediaType
        self.base64 = base64
    }
}

/// 把附件的引用解析成可发送的字节。
///
/// 设计成异步 + 批量：图片要读盘、要 base64 编码，几十 KB 到几 MB 不等，
/// 放在请求构造的同步路径上会卡住调用方。
public protocol ImageResolver: Sendable {
    func resolve(_ refs: [ImageAttachmentRef]) async -> [String: ResolvedImage]
}

/// 收集一条请求里所有图片引用。
func collectImageRefs(_ options: GenerateOptions) -> [ImageAttachmentRef] {
    var seen = Set<String>()
    var refs: [ImageAttachmentRef] = []
    for message in options.messages {
        for block in message.blocks {
            guard case let .image(ref) = block else { continue }
            if seen.insert(ref.id).inserted {
                refs.append(ref)
            }
        }
    }
    return refs
}

func resolveImages(
    _ options: GenerateOptions,
    profile: ProviderProfile,
    resolver: (any ImageResolver)?
) async -> [String: ResolvedImage] {
    // 不支持视觉的模型直接丢弃图片，不发出去让厂商报 400。
    guard profile.capabilities.vision, let resolver else { return [:] }
    let refs = collectImageRefs(options)
    guard !refs.isEmpty else { return [:] }
    return await resolver.resolve(refs)
}
