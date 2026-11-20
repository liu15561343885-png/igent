import CoreKit
import Foundation

/// 真实网络传输：`URLSession` 字节流 → 数据块。
public struct URLSessionTransport: StreamTransport {
    private let session: URLSession

    /// 流式对话的默认会话。
    ///
    /// `.shared` 的请求超时是 60 秒，而这个超时管的是"等到首个字节"——
    /// 推理模型常见 20–60 秒才出首字，正好卡在边界上，会被误报成网络中断。
    /// 这里放宽到 180 秒；一旦开始出字节，超时会随每次接收重置。
    public static let streaming: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    public init(session: URLSession = URLSessionTransport.streaming) {
        self.session = session
    }

    public func bytes(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (stream, response) = try await session.bytes(for: request)

                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        let body = try await Self.drain(stream, limit: 8192)
                        let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
                        throw LlmFailure.from(
                            status: http.statusCode,
                            body: String(decoding: body, as: UTF8.self),
                            retryAfterSeconds: retryAfter
                        )
                    }

                    var buffer = Data()
                    for try await byte in stream {
                        buffer.append(byte)
                        if buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func drain(_ stream: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in stream {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }
}
