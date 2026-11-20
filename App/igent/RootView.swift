import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showDebugSettings = false
    @State private var showDebugSkills = false

    var body: some View {
        NavigationStack {
            Group {
                if let chat = env.chat {
                    ChatView(model: chat)
                } else if env.profiles.isEmpty {
                    onboarding
                } else {
                    // 兜底：有厂商却没有会话（引导完成、删光会话、或初始化顺序问题）。
                    // 这里必须真的去建会话，否则就是一个永远转下去的圈。
                    ProgressView()
                        .controlSize(.large)
                        .task { await env.ensureSession() }
                }
            }
        }
        .task {
            await env.bootstrap()
            #if DEBUG
            // 仅用于模拟器截图：`-openSettings` 直接打开设置页。
            if ProcessInfo.processInfo.arguments.contains("-openSettings") {
                showDebugSettings = true
            }
            if ProcessInfo.processInfo.arguments.contains("-openSkills") {
                showDebugSkills = true
            }
            #endif
        }
        .sheet(isPresented: $showDebugSettings) {
            ProviderSettingsView()
        }
        .sheet(isPresented: $showDebugSkills) {
            NavigationStack { SkillListView() }
        }
    }

    /// 第一次启动：没有厂商时的引导页。
    private var onboarding: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating.speed(0.4))

            VStack(spacing: 8) {
                Text("igent")
                    .font(.largeTitle.bold())
                Text("接入你自己的 API，直接开始对话。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            NavigationLink {
                ProviderSettingsView()
            } label: {
                Text("添加厂商")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
}
