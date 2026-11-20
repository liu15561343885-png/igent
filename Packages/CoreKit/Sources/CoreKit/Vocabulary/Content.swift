import Foundation

public typealias MessageID = UUID

/// 内容块的种类标签。与传输层无关，供装配、渲染、计量共用。
public enum BlockType: String, Codable, Sendable, CaseIterable {
    case text
    case reasoning
    case image
    case context
    case citation
    /// 用户上传并解析过的文档。
    case document
    /// 厂商私有的不透明块（如 DeepSeek 的 `server_tool_use`）。
    /// 必须**原样回传**给厂商，否则多轮之后读过或搜过的内容会从上下文里消失。
    case provider
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

/// 已解析的文档。正文在解析时抽取好，请求里作为普通文本发给模型——
/// 这样任何厂商都能读，不依赖各家互不兼容的文件接口。
public struct DocumentAttachment: Codable, Sendable, Equatable {
    public var name: String
    public var pageCount: Int
    /// 解析出的纯文本（各页按顺序拼接）。
    public var text: String
    /// 原文是否因长度上限被截断。
    public var truncated: Bool

    public init(name: String, pageCount: Int, text: String, truncated: Bool = false) {
        self.name = name
        self.pageCount = pageCount
        self.text = text
        self.truncated = truncated
    }

    /// 单个文档注入上下文的上限。超过这个量，模型也读不完，
    /// 不如明确截断并告知，而不是让请求直接超窗。
    static let promptLimit = 24_000

    /// 发给模型的形式：文件头 + 正文。
    public var promptText: String {
        let header = "【文件：\(name)（\(pageCount) 页）】"
        var body = text
        var note = ""
        if body.count > Self.promptLimit {
            body = String(body.prefix(Self.promptLimit))
            note = "\n…（文件较长，后续内容已截断）"
        } else if truncated {
            note = "\n…（原文超出识别长度上限，部分内容未解析）"
        }
        return header + "\n" + body + note
    }
}

/// 厂商私有的不透明块。
///
/// 我们不解析它的语义，只保证两件事：原样存进事件日志、原样拼回下一次请求。
/// DeepSeek 的 `web_fetch_tool_result` 把网页正文加密在 `signature` 里，
/// 丢了它就等于丢了"上一轮读过的那一页"。
public struct ProviderBlock: Codable, Sendable, Equatable {
    /// 厂商块的类型标签，例如 `server_tool_use`、`web_search_tool_result`。
    public var type: String
    /// 原始 JSON，不做任何改写。
    public var payload: JSONValue

    public init(type: String, payload: JSONValue) {
        self.type = type
        self.payload = payload
    }
}

/// 模型可见的内容块。闭合枚举：新增种类必须同时处理装配、渲染与计量。
public enum ContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case image(ImageAttachmentRef)
    case context(ContextEvidence)
    case citation(Citation)
    case document(DocumentAttachment)
    case providerBlock(ProviderBlock)

    public var type: BlockType {
        switch self {
        case .text: .text
        case .reasoning: .reasoning
        case .image: .image
        case .context: .context
        case .citation: .citation
        case .document: .document
        case .providerBlock: .provider
        }
    }

    /// 纯文本投影：用于 token 估算、FTS 与摘要。
    public var plainText: String {
        switch self {
        case let .text(value), let .reasoning(value):
            value
        case let .context(evidence):
            evidence.digest
        case let .document(document):
            document.text
        case .image, .citation, .providerBlock:
            ""
        }
    }
}
