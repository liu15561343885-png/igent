import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            Group {
                if let chat = env.chat {
                    ChatView(model: chat)
                } else if env.profiles.isEmpty {
                    onboarding
                } else {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .task {
            await env.bootstrap()
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
