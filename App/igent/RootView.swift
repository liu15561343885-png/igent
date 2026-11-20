import CoreKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showDebugSettings = false
    @State private var showDebugSkills = false

    var body: some View {
        ZStack(alignment: .leading) {
            navigationRoot

            if env.showSessionDrawer {
                // 遮罩和面板必须是**兄弟**视图，各自带 transition。
                // 之前包在一个 sessionDrawer 里，外层 `if` 插入的是容器本身，
                // 用的是默认的淡入淡出——里面的 .move 从未生效。
                drawerBackdrop
                drawerPanel
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: env.showSessionDrawer)
    }

    private var navigationRoot: some View {
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            env.didEnterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            env.willEnterForeground()
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

    /// 左侧会话抽屉。
    ///
    /// 放在外壳层而不是页面里：只有这样才能盖住导航栏，
    /// 让抽屉的标题栏占住原本导航栏的位置。
    private var drawerBackdrop: some View {
        Color.black.opacity(0.22)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { closeDrawer() }
            .transition(.opacity)
            .zIndex(1)
    }

    /// 面板：从左侧滑入滑出，不做淡入淡出。
    private var drawerPanel: some View {
        ZStack(alignment: .leading) {
            SessionListView(
                currentSessionID: env.chat?.sessionID ?? UUID(),
                onClose: { closeDrawer() }
            )
            .frame(width: 312)
            .background(.regularMaterial)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 16,
                    style: .continuous
                )
            )
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.5), .white.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.24), radius: 22, x: 8, y: 0)
            .ignoresSafeArea(edges: .vertical)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .leading))
        .zIndex(2)
    }

    private func closeDrawer() {
        env.showSessionDrawer = false
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
