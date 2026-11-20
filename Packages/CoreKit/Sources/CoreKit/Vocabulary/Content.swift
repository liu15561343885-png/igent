import Foundation

public typealias MessageID = UUID

/// 内容块的种类标签。与传输层无关，供装配、渲染、计量共用。
public enum BlockType: String, Codable, Sendable, CaseIterable {
    case text
    case reasoning
    case image
    case context
    case citation
}

/// 一张已落盘的图片引用。内容寻址，不携路径语义。
public struct ImageAttachmentRef: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var mediaType: String
    public var byteCount: Int
    public var width: Int
    public var height: Int
    /// 相对 Application Support 的存储路径，由 Attachments 层维护。
    public var relativePath: String?

    public init(
        id: String,
        mediaType: String,
        byteCount: Int,
        width: Int,
        height: Int,
        relativePath: String? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.relativePath = relativePath
    }
}

/// 一个可引用的来源。url 必填，其余字段缺省即供应商没给——不编造。
public struct WebSource: Codable, Sendable, Equatable, Identifiable {
    public var url: URL
    public var title: String?
    public var snippet: String?
    public var publishedAt: String?

    public var id: String { url.absoluteString }

    public init(url: URL, title: String? = nil, snippet: String? = nil, publishedAt: String? = nil) {
        self.url = url
        self.title = title
        self.snippet = snippet
        self.publishedAt = publishedAt
    }
}

/// 检索证据。取代 agent 框架里的 tool-result 块，只能由编排器写入。
public struct ContextEvidence: Codable, Sendable, Equatable {
    public var query: String
    public var sources: [WebSource]
    /// 清洗、去重、按预算截断后的正文，含 `[1]` `[2]` 编号。
    public var digest: String
    public var fetchedAt: Date
    public var truncated: Bool

    public init(
        query: String,
        sources: [WebSource],
        digest: String,
        fetchedAt: Date,
        truncated: Bool
    ) {
        self.query = query
        self.sources = sources
        self.digest = digest
        self.fetchedAt = fetchedAt
        self.truncated = truncated
    }
}

/// 正文中的引用标注。UI 渲染为上标，模型侧不发送。
public struct Citation: Codable, Sendable, Equatable {
    public var index: Int
    public var url: URL
    public var title: String?

    public init(index: Int, url: URL, title: String? = nil) {
        self.index = index
        self.url = url
        self.title = title
    }
}

/// 模型可见的内容块。闭合枚举：新增种类必须同时处理装配、渲染与计量。
public enum ContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case image(ImageAttachmentRef)
    case context(ContextEvidence)
    case citation(Citation)

    public var type: BlockType {
        switch self {
        case .text: .text
        case .reasoning: .reasoning
        case .image: .image
        case .context: .context
        case .citation: .citation
        }
    }

    /// 纯文本投影：用于 token 估算、FTS 与摘要。
    public var plainText: String {
        switch self {
        case let .text(value), let .reasoning(value):
            value
        case let .context(evidence):
            evidence.digest
        case .image, .citation:
            ""
        }
    }
}
