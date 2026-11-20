import CoreKit
import Foundation

/// 由 `ProviderProfile` 造出对应适配器。设置页只存 profile，运行期用这里装配。
public enum AdapterFactory {
    public static func make(
        profile: ProviderProfile,
        apiKey: String,
        transport: StreamTransport = URLSessionTransport(),
        imageResolver: (any ImageResolver)? = nil
    ) -> any LlmAdapter {
        switch profile.family {
        case .openAICompatible:
            OpenAICompatibleAdapter(
                profile: profile, apiKey: apiKey,
                transport: transport, imageResolver: imageResolver
            )
        case .openAIResponses:
            OpenAIResponsesAdapter(
                profile: profile, apiKey: apiKey,
                transport: transport, imageResolver: imageResolver
            )
        case .anthropic:
            AnthropicAdapter(
                profile: profile, apiKey: apiKey,
                transport: transport, imageResolver: imageResolver
            )
        case .gemini:
            GeminiAdapter(
                profile: profile, apiKey: apiKey,
                transport: transport, imageResolver: imageResolver
            )
        }
    }
}
