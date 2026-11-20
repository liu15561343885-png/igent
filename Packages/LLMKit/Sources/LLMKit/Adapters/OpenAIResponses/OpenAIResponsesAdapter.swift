import CoreKit
import Foundation

public struct OpenAIResponsesAdapter: LlmAdapter {
    public let profile: ProviderProfile
    public let apiKey: String
    public let transport: StreamTransport
    public let imageResolver: (any ImageResolver)?

    public init(
        profile: ProviderProfile = .openAIResponses(),
        apiKey: String,
        transport: StreamTransport = URLSessionTransport(),
        imageResolver: (any ImageResolver)? = nil
    ) {
        self.profile = profile
        self.apiKey = apiKey
        self.transport = transport
        self.imageResolver = imageResolver
    }

    public func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let images = await resolveImages(options, profile: profile, resolver: imageResolver)
                    let request = try makeRequest(options, images: images)
                    var parser = OpenAIResponsesStreamParser()
                    for try await data in transport.bytes(for: request) {
                        for chunk in parser.feed(data) {
                            continuation.yield(chunk)
                        }
                    }
                    for chunk in parser.finish() {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finish(.aborted(LlmFailure(message: "已取消", code: .cancelled)), meta: nil))
                    continuation.finish()
                } catch let failure as LlmFailure {
                    continuation.yield(.finish(.error(failure), meta: nil))
                    continuation.finish()
                } catch {
                    continuation.yield(.finish(.error(LlmFailure(message: error.localizedDescription, code: .network)), meta: nil))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeRequest(_ options: GenerateOptions, images: [String: ResolvedImage] = [:]) throws -> URLRequest {
        guard let url = profile.chatURL(for: options.model) else {
            throw AdapterError.invalidURL(profile.baseURL.absoluteString + profile.chatPath)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        RequestAuth.apply(profile.auth, apiKey: apiKey, to: &request)
        for (key, value) in profile.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let body = OpenAIResponsesRequestBuilder(profile: profile).body(options) { ref in
            images[ref.id].map { "data:\($0.mediaType);base64,\($0.base64)" }
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}
