import CoreKit
import Foundation
import LLMKit

/// 把附件存储里的图片读出来交给适配器。
///
/// 放在 StorageKit 而不是 app 里：它同时依赖 CoreKit（引用）与 LLMKit（协议），
/// 正好是这一层的职责边界。
public struct StorageImageResolver: ImageResolver {
    private let store: AttachmentStore?

    public init(store: AttachmentStore?) {
        self.store = store
    }

    public func resolve(_ refs: [ImageAttachmentRef]) async -> [String: ResolvedImage] {
        var resolved: [String: ResolvedImage] = [:]
        for ref in refs {
            guard let store else { continue }
            guard let data = try? await store.data(for: ref) else { continue }
            resolved[ref.id] = ResolvedImage(
                mediaType: ref.mediaType,
                base64: data.base64EncodedString()
            )
        }
        return resolved
    }
}
