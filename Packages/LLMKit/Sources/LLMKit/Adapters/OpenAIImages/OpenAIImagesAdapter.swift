import CoreKit
import Foundation

/// OpenAI Images（`/images/generations`）。
///
/// 两种返回都要处理：
/// - `gpt-image-1` 只返回 `b64_json`，且**不接受** `response_format` 参数；
/// - `dall-e-3` 默认返回 `url`，需要再下载一次。
public struct OpenAIImagesAdapter: ImageGenerationAdapter {
    public let profile: ProviderProfile
    public let apiKey: String
    private let session: URLSession

    public init(
        profile: ProviderProfile,
        apiKey: String,
        session: URLSession = .shared
    ) {
        self.profile = profile
        self.apiKey = apiKey
        self.session = session
    }

    public static func profile(
        id: String = "openai-images",
        name: String = "OpenAI Images",
        baseURL: String = "https://api.openai.com/v1"
    ) -> ProviderProfile {
        ProviderProfile(
            id: id,
            name: name,
            family: .openAICompatible,
            baseURL: URL(string: baseURL)!,
            chatPath: "/images/generations",
            capabilities: Capabilities(imageOut: true)
        )
    }

    // MARK: - 请求

    func makeRequest(_ request: ImageGenerationRequest) throws -> URLRequest {
        guard let url = profile.url(forPath: profile.chatPath) else {
            throw AdapterError.invalidURL(profile.baseURL.absoluteString)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        RequestAuth.apply(profile.auth, apiKey: apiKey, to: &urlRequest)
        for (key, value) in profile.extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "prompt": .string(request.prompt),
            "n": .number(Double(request.count))
        ]
        if let size = request.size {
            body["size"] = .string(size)
        }
        for (key, value) in request.extras {
            body[key] = value
        }
        urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        return urlRequest
    }

    // MARK: - 解析

    /// 从响应里取出 base64 或下载地址。两种都要留着：厂商不保证返回哪一种。
    static func parse(_ data: Data) throws -> [(base64: String?, url: URL?)] {
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
        guard let items = object["data"]?.arrayValue else {
            throw ImageGenerationError.unsupportedShape("缺少 data 数组")
        }

        let parsed = items.compactMap { item -> (String?, URL?)? in
            guard let entry = item.objectValue else { return nil }
            let base64 = entry["b64_json"]?.stringValue
            let url = entry["url"]?.stringValue.flatMap(URL.init(string:))
            guard base64 != nil || url != nil else { return nil }
            return (base64, url)
        }
        guard !parsed.isEmpty else { throw ImageGenerationError.emptyResponse }
        return parsed
    }

    // MARK: - 执行

    public func generate(_ request: ImageGenerationRequest) async throws -> [GeneratedImage] {
        let urlRequest = try makeRequest(request)
        let (data, response) = try await session.data(for: urlRequest)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LlmFailure.from(
                status: http.statusCode,
                body: String(decoding: data.prefix(1000), as: UTF8.self)
            )
        }

        var images: [GeneratedImage] = []
        for item in try Self.parse(data) {
            if let base64 = item.base64, let decoded = Data(base64Encoded: base64) {
                images.append(GeneratedImage(data: decoded, mediaType: "image/png"))
            } else if let url = item.url {
                let (bytes, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw ImageGenerationError.downloadFailed(http.statusCode)
                }
                images.append(GeneratedImage(data: bytes, mediaType: "image/png"))
            }
        }
        guard !images.isEmpty else { throw ImageGenerationError.emptyResponse }
        return images
    }
}
