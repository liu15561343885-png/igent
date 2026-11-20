import CoreKit
import Foundation

/// 一家厂商的流式对话适配器。
///
/// 实现者只负责两件事：把 `GenerateOptions` 译成厂商报文，把厂商的流式帧译回
/// `StreamChunk`。任何厂商字段名都不得越过这一层。
public protocol LlmAdapter: Sendable {
    var profile: ProviderProfile { get }
    func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error>
}

/// 把 HTTP 响应体切成字节块。抽成协议是为了能在单测里喂录制好的 fixture。
public protocol StreamTransport: Sendable {
    func bytes(for request: URLRequest) -> AsyncThrowingStream<Data, Error>
}

public enum AdapterError: Error, Equatable {
    case invalidURL(String)
    case missingCredential
}

extension LlmFailure {
    /// 把 HTTP 状态码归一成稳定错误类别。
    public static func from(status: Int, body: String, retryAfterSeconds: Int? = nil) -> LlmFailure {
        let lowercased = body.lowercased()
        let code: LlmErrorCode
        switch status {
        case 401, 403:
            code = .auth
        case 429:
            code = .rateLimit
        case 400, 413, 422 where lowercased.contains("context") || lowercased.contains("too long"):
            code = .contextWindowExceeded
        case 400, 422 where lowercased.contains("image"):
            code = .imageTooLarge
        case 400..<500:
            code = .invalidCredential
        default:
            code = status >= 500 ? .server : .network
        }
        return LlmFailure(
            message: body.isEmpty ? "HTTP \(status)" : body,
            code: code,
            status: status,
            providerRetryAfterMs: retryAfterSeconds.map { $0 * 1000 }
        )
    }
}
