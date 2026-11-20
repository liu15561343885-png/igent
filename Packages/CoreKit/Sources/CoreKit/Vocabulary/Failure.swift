import Foundation

/// 稳定、可编程路由的失败类别。**永远按 code 分支，不要解析 message。**
public enum LlmErrorCode: String, Codable, Sendable, CaseIterable {
    case auth
    case invalidCredential
    /// 4xx 但既不是鉴权、也不是配额或超窗（参数错误、模型不存在、格式不支持等）。
    case invalidRequest
    case rateLimit
    case quota
    case contextWindowExceeded
    /// 正常结束但零内容。厂商偶发，必须归为可重试失败，不能落一条空消息。
    case emptyResponse
    case noAdapter
    case cancelled
    case server
    case network
    case contentFilter
    case unsupportedCapability
    case imageTooLarge
    case decodeFailed
}

public struct LlmFailure: Error, Codable, Sendable, Equatable {
    public var message: String
    public var code: LlmErrorCode
    public var status: Int?
    public var providerRetryAfterMs: Int?
    public var requestId: String?

    public init(
        message: String,
        code: LlmErrorCode,
        status: Int? = nil,
        providerRetryAfterMs: Int? = nil,
        requestId: String? = nil
    ) {
        self.message = message
        self.code = code
        self.status = status
        self.providerRetryAfterMs = providerRetryAfterMs
        self.requestId = requestId
    }

    /// 可重试类别。其余一律不重试——重试只会重复失败。
    public var isRetryable: Bool {
        switch code {
        case .rateLimit, .server, .network, .emptyResponse, .decodeFailed:
            true
        case .auth, .invalidCredential, .invalidRequest, .quota, .contextWindowExceeded,
             .contentFilter, .unsupportedCapability, .imageTooLarge,
             .noAdapter, .cancelled:
            false
        }
    }
}

/// 为什么结束。
public enum FinishReason: Codable, Sendable, Equatable {
    case stop
    case maxTokens
    case contentFilter(String?)
    case aborted(LlmFailure)
    case error(LlmFailure)

    /// 是否属于异常结束。
    public var isFailure: Bool {
        switch self {
        case .aborted, .error: true
        case .stop, .maxTokens, .contentFilter: false
        }
    }
}
