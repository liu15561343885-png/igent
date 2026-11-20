import CoreKit
import Foundation

/// 真实网络传输：`URLSession` 字节流 → 数据块。
public struct URLSessionTransport: StreamTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
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
