import CoreKit
import Foundation
import LLMKit
import Observation
import StorageKit

/// 图片生成用哪家、哪个模型——与对话厂商**分开配置**。
///
/// 为什么必须分开：能聊天的厂商不一定能画图（DeepSeek、Kimi 都没有图像模型），
/// 而能画图的（如 OpenAI Images）也可能和当前对话用的不是同一个账号/额度。
struct ImageProviderSettings: Sendable, Equatable {
    var family: ProviderFamily
    var baseURL: String
    var model: String

    static let `default` = ImageProviderSettings(
        family: .openAICompatible,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-image-1"
    )
}

private enum ImageSettingsKey {
    static let family = "imageProviderFamily"
    static let baseURL = "imageProviderBaseURL"
    static let model = "imageProviderModel"
    static let account = "imageprovider"
}

extension AppEnvironment {
    var imageSettings: ImageProviderSettings {
        get {
            let defaults = UserDefaults.standard
            let family = defaults.string(forKey: ImageSettingsKey.family)
                .flatMap(ProviderFamily.init(rawValue:)) ?? .openAICompatible
            return ImageProviderSettings(
                family: family,
                baseURL: defaults.string(forKey: ImageSettingsKey.baseURL)
                    ?? ImageProviderSettings.default.baseURL,
                model: defaults.string(forKey: ImageSettingsKey.model)
                    ?? ImageProviderSettings.default.model
            )
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.family.rawValue, forKey: ImageSettingsKey.family)
            defaults.set(newValue.baseURL, forKey: ImageSettingsKey.baseURL)
            defaults.set(newValue.model, forKey: ImageSettingsKey.model)
            imageProviderRevision += 1
        }
    }

    var imageAPIKey: String {
        keychain.get(Keychain.account(for: ImageSettingsKey.account)) ?? ""
    }

    func setImageAPIKey(_ value: String) {
        if value.isEmpty {
            keychain.delete(Keychain.account(for: ImageSettingsKey.account))
        } else {
            try? keychain.set(value, for: Keychain.account(for: ImageSettingsKey.account))
        }
        imageProviderRevision += 1
    }

    var isImageGenerationConfigured: Bool {
        !imageAPIKey.isEmpty && !imageSettings.model.isEmpty
    }

    /// 用独立配置构造生成适配器，不碰对话厂商。
    func makeImageAdapter() -> (any ImageGenerationAdapter)? {
        guard isImageGenerationConfigured else { return nil }
        let settings = imageSettings
        let key = imageAPIKey

        switch settings.family {
        case .gemini:
            return GeminiImagesAdapter(
                profile: GeminiImagesAdapter.profile(baseURL: settings.baseURL),
                apiKey: key
            )
        default:
            return OpenAIImagesAdapter(
                profile: OpenAIImagesAdapter.profile(baseURL: settings.baseURL),
                apiKey: key
            )
        }
    }
}
