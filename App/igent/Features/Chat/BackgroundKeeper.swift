import UIKit

/// 生成过程中申请一段后台执行时间。
///
/// 没有任何"后台联网权限"这种设置：App 进入后台几秒后会被挂起，
/// 正在进行的 URLSession 请求随之中断。`beginBackgroundTask` 能换来约 30 秒，
/// 足够把大多数回合跑完——用户切出去看一眼再回来，答案通常还在。
@MainActor
final class BackgroundKeeper {
    private var token: UIBackgroundTaskIdentifier = .invalid

    func begin(reason: String) {
        guard token == .invalid else { return }
        token = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
            // 到期回调：不主动结束的话 App 会被系统强杀。
            self?.end()
        }
    }

    func end() {
        guard token != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token)
        token = .invalid
    }
}
