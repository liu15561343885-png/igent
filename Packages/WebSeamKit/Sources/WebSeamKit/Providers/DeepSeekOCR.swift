import CoreKit
import Foundation

/// 文档解析结果。
public struct RecognizedDocument: Sendable, Equatable {
    public var pageCount: Int
    /// 各页文本按顺序拼接。
    public var text: String
    /// 因长度上限被截断的页码（模型侧 finish_reason 为 length）。
    public var truncatedPages: [Int]
    public var inputTokens: Int?
    public var outputTokens: Int?

    public var isTruncated: Bool { !truncatedPages.isEmpty }
}

/// 把文档（PDF / Word / PPT / 图片）转成纯文本。
///
/// 为什么走服务端而不是本地解析：
/// - iOS 自带 PDFKit 只能读"有文字层"的 PDF，扫描件要另做 OCR；
/// - Word / PPT 需要自己解 ZIP + XML，工作量远大于收益；
/// - 服务端一次调用就能覆盖全部格式，还能识别扫描件。
///
/// 代价：按页计费（约 $0.225 / 千页）、单文件 100 MiB、1000 页、180 秒总时限。
public protocol DocumentRecognizer: Sendable {
    func recognize(data: Data, filename: String) async throws -> RecognizedDocument
}

public struct DeepSeekOCRRecognizer: DocumentRecognizer {
    public enum Purpose: String, Sendable {
        /// 只取文字，图表丢弃。合同、论文、扫描文本用这个。
        case textRecognition = "text_recognition"
        /// 文字 + 图表一起识别。财报、幻灯片、手册用这个。
        case richLayoutRecognition = "rich_layout_recognition"
    }

    public let apiKey: String
    public var purpose: Purpose
    private let session: URLSession

    public init(
        apiKey: String,
        purpose: Purpose = .textRecognition,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.purpose = purpose
        self.session = session
    }

    static func makeRequest(
        data: Data,
        filename: String,
        purpose: Purpose,
        apiKey: String
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/tools/ocr")!)
        request.httpMethod = "POST"
        // 文档上限 180 秒总时限，客户端留一点余量。
        request.timeoutInterval = 200
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        func append(_ text: String) {
            body.append(Data(text.utf8))
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n")
        append("\(purpose.rawValue)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        return request
    }

    /// 服务端在识别期间会持续发换行保活，响应体前面可能有一堆空行。
    static func parse(_ data: Data) throws -> RecognizedDocument {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw WebError.emptyBody
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = trimmed.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: jsonData))?.objectValue
        else {
            throw WebError.emptyBody
        }
        if let error = object["error"]?.objectValue {
            throw WebError.message(error["message"]?.stringValue ?? "ocr failed")
        }

        let pages = object["pages"]?.arrayValue ?? []
        var texts: [String] = []
        var truncated: [Int] = []
        for page in pages {
            let entry = page.objectValue
            let index = entry?["index"]?.numberValue.map { Int($0) } ?? texts.count
            texts.append(entry?["text"]?.stringValue ?? "")
            if entry?["finish_reason"]?.stringValue == "length" {
                truncated.append(index)
            }
        }

        let joined = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !joined.isEmpty else { throw WebError.emptyBody }

        let usage = object["usage"]?.objectValue
        return RecognizedDocument(
            pageCount: object["page_count"]?.numberValue.map { Int($0) } ?? pages.count,
            text: joined,
            truncatedPages: truncated,
            inputTokens: usage?["input_tokens"]?.numberValue.map { Int($0) },
            outputTokens: usage?["output_tokens"]?.numberValue.map { Int($0) }
        )
    }

    public func recognize(data: Data, filename: String) async throws -> RecognizedDocument {
        let request = Self.makeRequest(
            data: data,
            filename: filename,
            purpose: purpose,
            apiKey: apiKey
        )
        let (responseData, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebError.badStatus(http.statusCode)
        }
        return try Self.parse(responseData)
    }
}
