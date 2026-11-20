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

    /// SQLite 落在 Application Support，不进 iCloud 备份的资料目录。
    private static func databaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("igent.sqlite")
    }
}
