import SwiftUI

@main
struct IgentApp: App {
    @State private var environment: AppEnvironment

    init() {
        _environment = State(initialValue: AppEnvironment(databaseURL: Self.databaseURL()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
    }

    /// SQLite 落在 Application Support。
    /// 注意：这个目录**会**进 iCloud 备份（代码里没有设 isExcludedFromBackup），
    /// 换机恢复时聊天记录会一起回来；密钥在钥匙串里，不随备份迁移。
    private static func databaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("igent.sqlite")
    }
}
