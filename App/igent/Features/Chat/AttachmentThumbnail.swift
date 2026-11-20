import CoreKit
import SwiftUI

/// 从附件存储异步加载缩略图。
///
/// 图片字节不进 SwiftUI 的状态流：每次重绘都重新解一张几 MB 的图会明显掉帧。
struct AttachmentThumbnail: View {
    @Environment(AppEnvironment.self) private var env
    let reference: ImageAttachmentRef
    var maxSide: CGFloat = 200

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side * aspect)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: reference.id) {
            guard image == nil,
                  let data = try? await env.attachments.data(for: reference)
            else { return }
            image = UIImage(data: data)
        }
        .accessibilityLabel("图片附件")
    }

    /// 按原始比例算高度，避免所有图都被拉成正方形。
    private var aspect: CGFloat {
        let width = max(1, reference.width)
        let height = max(1, reference.height)
        return CGFloat(height) / CGFloat(width)
    }

    private var side: CGFloat {
        min(maxSide, CGFloat(reference.width))
    }
}
