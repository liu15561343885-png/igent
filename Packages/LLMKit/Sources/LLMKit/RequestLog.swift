import CoreKit
import Foundation

/// 一次请求的完整痕迹（已脱敏）。
///
/// 多厂商适配最费时间的是"到底发了什么、回来什么"。没有这个，用户只能看到
/// 一句"网络错误"。有了它，鉴权头写错、模型名拼错、端点少个 `/v1`，一眼就能看出来。
public struct RequestTrace: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var startedAt: Date
    public var provider: String
    public var method: String
    public var url: String
    /// 敏感头已替换为 `••••`，值不落盘。
    public var headers: [String: String]
    public var bodyPreview: String
    public var statusCode: Int?
    public var responsePreview: String
    public var failure: LlmFailure?
    public var duration: TimeInterval?
    public var receivedBytes: Int

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        provider: String,
        method: String,
        url: String,
        headers: [String: String],
        bodyPreview: String,
        statusCode: Int? = nil,
        responsePreview: String = "",
        failure: LlmFailure? = nil,
        duration: TimeInterval? = nil,
        receivedBytes: Int = 0
    ) {
        self.id = id
        self.startedAt = startedAt
        self.provider = provider
        self.method = method
        self.url = url
        self.headers = headers
        self.bodyPreview = bodyPreview
        self.statusCode = statusCode
        self.responsePreview = responsePreview
        self.failure = failure
        self.duration = duration
        self.receivedBytes = receivedBytes
    }
}

/// 环形缓冲的请求日志。只保留最近若干条，避免无限增长。
public actor RequestLog {
    private var traces: [RequestTrace] = []
    private let capacity: Int

    public init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    public func begin(_ trace: RequestTrace) -> UUID {
        traces.append(trace)
        if traces.count > capacity {
            traces.removeFirst(traces.count - capacity)
        }
        return trace.id
    }

    public func complete(
        id: UUID,
        statusCode: Int?,
        responsePreview: String,
        receivedBytes: Int,
        failure: LlmFailure?,
        duration: TimeInterval
    ) {
        guard let index = traces.firstIndex(where: { $0.id == id }) else { return }
        traces[index].statusCode = statusCode
        traces[index].responsePreview = responsePreview
        traces[index].receivedBytes = receivedBytes
        traces[index].failure = failure
        traces[index].duration = duration
    }

    public func all() -> [RequestTrace] {
        traces.sorted { $0.startedAt > $1.startedAt }
    }

    public func clear() {
        traces.removeAll()
    }
}

/// 记录请求痕迹的传输层包装。本身不改变字节流，只是旁路观察。
public struct LoggingTransport: StreamTransport {
    private let upstream: StreamTransport
    private let log: RequestLog
    private let label: String
    private let previewLimit: Int

    public init(
        upstream: StreamTransport,
        log: RequestLog,
        label: String,
        previewLimit: Int = 4096
    ) {
        self.upstream = upstream
        self.log = log
        self.label = label
        self.previewLimit = previewLimit
    }

    public func bytes(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
                let id = await log.begin(
                    RequestTrace(
                        startedAt: startedAt,
                        provider: label,
                        method: request.httpMethod ?? "GET",
                        url: request.url?.absoluteString ?? "",
                        headers: Self.redacted(request.allHTTPHeaderFields ?? [:]),
                        bodyPreview: Self.bodyPreview(request.httpBody)
                    )
                )

                var preview = Data()
                var total = 0

                do {
                    for try await chunk in upstream.bytes(for: request) {
                        total += chunk.count
                        if preview.count < previewLimit {
                            preview.append(chunk.prefix(previewLimit - preview.count))
                        }
                        continuation.yield(chunk)
                    }
                    await log.complete(
                        id: id,
                        statusCode: nil,
                        responsePreview: String(decoding: preview, as: UTF8.self),
                        receivedBytes: total,
                        failure: nil,
                        duration: Date().timeIntervalSince(startedAt)
                    )
                    continuation.finish()
                } catch let failure as LlmFailure {
                    await log.complete(
                        id: id,
                        statusCode: failure.status,
                        responsePreview: String(decoding: preview, as: UTF8.self),
                        receivedBytes: total,
                        failure: failure,
                        duration: Date().timeIntervalSince(startedAt)
                    )
                    continuation.finish(throwing: failure)
                } catch {
                    await log.complete(
                        id: id,
                        statusCode: nil,
                        responsePreview: String(decoding: preview, as: UTF8.self),
                        receivedBytes: total,
                        failure: LlmFailure(message: error.localizedDescription, code: .network),
                        duration: Date().timeIntervalSince(startedAt)
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 脱敏

    static let sensitiveHeaders: Set<String> = [
        "authorization", "x-api-key", "api-key", "x-goog-api-key", "cookie"
    ]

    static func redacted(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, entry in
            if sensitiveHeaders.contains(entry.key.lowercased()) {
                result[entry.key] = "••••"
            } else {
                result[entry.key] = entry.value
            }
        }
    }

    /// 请求体里可能有用户原文，保留开头用于定位，长度受控。
    static func bodyPreview(_ body: Data?, limit: Int = 2048) -> String {
        guard let body else { return "" }
        let slice = body.prefix(limit)
        return String(decoding: slice, as: UTF8.self)
    }
}
