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
    /// 各厂商表示"超出上下文"的明确措辞。宁可漏判（退化成 invalidRequest），
    /// 也不能误判——误判会触发压缩，而压缩是不可逆的。
    static let overflowMarkers = [
        "context_length_exceeded",
        "context length",
        "maximum context",
        "prompt is too long",
        "too many tokens",
        "reduce the length of the messages",
        "exceeds the maximum"
    ]

    public static func from(status: Int, body: String, retryAfterSeconds: Int? = nil) -> LlmFailure {
        let lowercased = body.lowercased()
        let code: LlmErrorCode
        switch status {
        case 401, 403:
            code = .auth
        case 429:
            code = .rateLimit
        case 400..<500:
            // 4xx 的语义只能靠报文判断，逐条分开写——`case a, b, c where x` 的 where
            // 只作用于最后一个模式，会把「所有 400」都吞进条件分支。
            if Self.overflowMarkers.contains(where: { lowercased.contains($0) }) {
                code = .contextWindowExceeded
            } else if status == 402 || lowercased.contains("quota") {
                code = .quota
            } else {
                // 以前这里回落到 invalidCredential，会把"参数错误"显示成"密钥无效"；
                // 更糟的是用过宽的 `"context"` 子串判定，一个被拒的 context 字段
                // 就能触发压缩，把历史真的压掉。所以只认厂商的明确措辞。
                code = .invalidRequest
            }
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
