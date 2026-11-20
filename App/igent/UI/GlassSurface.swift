import SwiftUI

// MARK: - 液态玻璃
//
// 本机工具链：Xcode 16.4 / iOS 18.5 SDK —— SDK 里没有 `glassEffect`，
// 所以下面的 `#if compiler(>=6.2)` 分支**从未编译过**。
//
// ⚠️ 未验证：真 Liquid Glass 分支是按 iOS 26 API 写的骨架。
// 换到 Xcode 26（Swift 6.2+）后如果签名有出入，只需要改 `GlassModifier` 里的那一行。
//
// 对外只暴露 `.glass(...)`，两种实现签名一致，调用点不受影响。

extension View {
    /// 玻璃表面。iOS 26 走系统 Liquid Glass，更早的系统走近似实现。
    func glass(
        cornerRadius: CGFloat = 22,
        tint: Color = .clear,
        showsShadow: Bool = true
    ) -> some View {
        modifier(GlassModifier(cornerRadius: cornerRadius, tint: tint, showsShadow: showsShadow))
    }
}

struct GlassModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color
    var showsShadow: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // 真 · Liquid Glass（未在本机验证，见文件头说明）。
            content.glassEffect(
                .regular.tint(tint).interactive(),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            content.modifier(LegacyGlass(cornerRadius: cornerRadius, tint: tint, showsShadow: showsShadow))
        }
        #else
        content.modifier(LegacyGlass(cornerRadius: cornerRadius, tint: tint, showsShadow: showsShadow))
        #endif
    }
}

// MARK: - iOS 18 近似实现

/// 用系统材质 + 渐变描边 + 上缘高光近似玻璃的层次感。
struct LegacyGlass: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color
    var showsShadow: Bool

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

/// 对话页背景。玻璃要有东西可以"透"，纯色底看不出层次。
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
