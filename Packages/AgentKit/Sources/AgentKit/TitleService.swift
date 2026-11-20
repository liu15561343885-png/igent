import CoreKit
import Foundation
import LLMKit
import StorageKit

/// 用一次很短的小模型调用，给会话起个标题。
///
/// 只在会话还是默认名时触发，且失败就静默放弃——标题是锦上添花，
/// 不值得为它弹错误提示。
public actor TitleService {
    private let store: SessionStore
    private let runtime: LlmRuntime

    public init(store: SessionStore, runtime: LlmRuntime) {
        self.store = store
        self.runtime = runtime
    }

    static let systemPrompt = """
    用不超过 12 个汉字概括下面这段对话的主题。只输出标题本身：
    不要引号、不要句号、不要"关于"开头、不要解释。
    """

    /// 返回并写回新标题；不值得起名时返回 nil。
    @discardableResult
    public func generateTitle(
        sessionID: SessionID,
        provider: String,
        model: String
    ) async -> String? {
        guard let session = try? await store.session(sessionID) else { return nil }
        // 已经有自定义标题就不覆盖。
        guard session.title == "新对话" || session.title.isEmpty else { return nil }

        guard let projection = try? await store.projection(for: sessionID) else { return nil }
        let firstUser = projection.messages.first { $0.role == .user }?.visibleText ?? ""
        let firstAssistant = projection.messages.first { $0.role == .assistant }?.visibleText ?? ""
        guard !firstUser.isEmpty else { return nil }

        let excerpt = """
        用户：\(String(firstUser.prefix(500)))

        助手：\(String(firstAssistant.prefix(500)))
        """

        let options = GenerateOptions(
            provider: provider,
            model: model,
            messages: [Message(role: .user, blocks: [.text(excerpt)], source: .user)],
            system: Self.systemPrompt,
            maxTokens: 32,
            purpose: .sessionTitle
        )

        var assembler = BlockAssembler()
        do {
            for try await chunk in await runtime.stream(options) {
                assembler.push(chunk)
            }
        } catch {
            // 起标题失败不值得打扰用户。
            return nil
        }
        let raw = (try? assembler.blocks())?.answerText ?? ""
        guard let title = Self.clean(raw) else { return nil }

        try? await store.rename(sessionID, to: title)
        return title
    }

    /// 去掉模型爱加的花边：引号、书名号、结尾句号、换行。
    static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 推理草稿常带 **加粗**、# 标题；模型偶尔也会学样。
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "*#_` "))
        text = text.components(separatedBy: .newlines).first ?? text
        // 引号、句号、Markdown 强调可能以任意顺序堆在两端（"「标题」。"），
        // 分两轮按类别剥会漏；统一成一个字符集循环剥到稳定为止。
        let trivia = Set("\"'“”「」《》‘’。.!！*#_` ")
        while let first = text.first, trivia.contains(first) { text.removeFirst() }
        while let last = text.last, trivia.contains(last) { text.removeLast() }

        guard !text.isEmpty else { return nil }
        return String(text.prefix(24))
    }
}
