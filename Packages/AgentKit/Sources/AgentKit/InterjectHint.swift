import Foundation

/// 插话时附加给模型的系统提示。
///
/// 各家 API 都没有"边生成边追加指令"的能力，插话只能做成"中断 + 带新指示重开一轮"。
/// 关键是不能让模型把前半段当成没发生过——否则它会从头再说一遍，
/// 用户看到的是一次没必要的重启，而不是方向被修正。
public enum InterjectHint {
    public static let instruction = """
    用户在你输出过程中插话，请据此调整方向：保留仍然成立的部分，不要重复已经说过的内容，也不要复述这次打断。
    """

    /// 把插话提示拼到既有 system 后面；没有 system 时直接用提示。
    public static func system(base: String?) -> String {
        guard let base, !base.isEmpty else { return instruction }
        return base + "\n\n" + instruction
    }

    /// 用户消息前缀，让这一轮在对话记录里一眼可辨。
    public static func userText(_ text: String) -> String {
        "【插话】" + text
    }
}
