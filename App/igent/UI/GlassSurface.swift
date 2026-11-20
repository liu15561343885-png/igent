import SwiftUI

/// iOS 18 上近似"液态玻璃"的表面。
///
/// 真正的 Liquid Glass（`glassEffect` / `GlassEffectContainer`）需要 iOS 26 SDK。
/// 本机是 Xcode 16.4 + iOS 18.5 SDK，SDK 里没有这些符号，写 `if #available` 也编译不过。
/// 所以这里用系统材质 + 渐变描边 + 上缘高光来近似；等工具链升级到 Xcode 26 后，
/// **只需要替换这一个文件的实现**，调用点不用动。
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 22
    var tint: Color = .clear
    var showsShadow: Bool = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background(tint.opacity(0.22), in: shape)
            .overlay {
                // 亮边：左上偏白、右下渐暗，模拟玻璃边缘的折射
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .overlay(alignment: .top) {
                // 上缘高光带
                LinearGradient(
                    colors: [.white.opacity(0.22), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 26)
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            .shadow(
                color: showsShadow ? .black.opacity(0.12) : .clear,
                radius: showsShadow ? 14 : 0,
                y: showsShadow ? 5 : 0
            )
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 22, tint: Color = .clear, showsShadow: Bool = true) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint, showsShadow: showsShadow))
    }
}

/// 对话页的背景。玻璃要有东西可以"透"，纯色底看不出层次。
struct GlassBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(.systemBackground),
                Color.accentColor.opacity(0.10),
                Color(.systemBackground)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
