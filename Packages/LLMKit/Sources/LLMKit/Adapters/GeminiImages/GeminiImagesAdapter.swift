import CoreKit
import Foundation

/// Gemini 的图像生成：走 `generateContent`，用 `responseModalities` 要求返回图片。
///
/// 与 OpenAI Images 的形态完全不同——它本质仍是"对话一次"，图片放在
/// `candidates[].content.parts[].inlineData` 里，和文字混在同一层。
public struct GeminiImagesAdapter: ImageGenerationAdapter {
    public let profile: ProviderProfile
    public let apiKey: String
    private let session: URLSession

    public init(
        profile: ProviderProfile = GeminiImagesAdapter.profile(),
        apiKey: String,
        session: URLSession = .shared
    ) {
        self.profile = profile
        self.apiKey = apiKey
        self.session = session
    }

    public static func profile(
        id: String = "gemini-images",
        name: String = "Gemini Images",
        baseURL: String = "https://generativelanguage.googleapis.com/v1beta"
    ) -> ProviderProfile {
        ProviderProfile(
            id: id,
            name: name,
            family: .gemini,
            baseURL: URL(string: baseURL)!,
            chatPath: "/models/{model}:generateContent",
            capabilities: Capabilities(imageOut: true, systemStyle: .systemInstruction),
            auth: .apiKey(header: "x-goog-api-key")
        )
    }

    func makeRequest(_ request: ImageGenerationRequest) throws -> URLRequest {
        guard let url = profile.chatURL(for: request.model) else {
            throw AdapterError.invalidURL(profile.baseURL.absoluteString)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        RequestAuth.apply(profile.auth, apiKey: apiKey, to: &urlRequest)

        var body: [String: JSONValue] = [
            "contents": .array([
                .object([
                    "role": .string("user"),
                    "parts": .array([.object(["text": .string(request.prompt)])])
                ])
            ]),
            "generationConfig": .object([
                "responseModalities": .array([.string("TEXT"), .string("IMAGE")])
            ])
        ]
        for (key, value) in request.extras {
            body[key] = value
        }
        urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        return urlRequest
    }

    /// 图片在 `inlineData` 里；同一次响应可能还带解释文字，这里只取图。
    static func parse(_ data: Data) throws -> [GeneratedImage] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else {
            throw ImageGenerationError.unsupportedShape(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let error = object["error"]?.objectValue {
            throw LlmFailure.from(
                status: 400,
                body: error["message"]?.stringValue ?? "image generation failed"
            )
        }

        var images: [GeneratedImage] = []
        for candidate in object["candidates"]?.arrayValue ?? [] {
            let parts = candidate.objectValue?["content"]?.objectValue?["parts"]?.arrayValue ?? []
            for part in parts {
                guard let inline = part.objectValue?["inlineData"]?.objectValue,
                      let encoded = inline["data"]?.stringValue,
                      let bytes = Data(base64Encoded: encoded)
                else { continue }
                let mime = inline["mimeType"]?.stringValue ?? "image/png"
                images.append(GeneratedImage(data: bytes, mediaType: mime))
            }
        }
        guard !images.isEmpty else { throw ImageGenerationError.emptyResponse }
        return images
    }

    public func generate(_ request: ImageGenerationRequest) async throws -> [GeneratedImage] {
        let urlRequest = try makeRequest(request)
        let (data, response) = try await session.data(for: urlRequest)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LlmFailure.from(
                status: http.statusCode,
                body: String(decoding: data.prefix(1000), as: UTF8.self)
            )
        }
        return try Self.parse(data)
    }
}
