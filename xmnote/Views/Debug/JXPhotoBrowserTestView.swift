#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 XMJXImageWall 组件与演示图片数据集
 * [OUTPUT]: 对外提供 JXPhotoBrowserTestView（JX 浏览器集成测试页）
 * [POS]: Debug 测试页，用于验证 UIKit JXPhotoBrowser 在 SwiftUI 场景下的 Zoom 转场、下滑关闭与缩略图显隐一致性
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct JXPhotoBrowserTestView: View {
    private let items: [XMJXGalleryItem] = {
        let baseURL = "https://raw.githubusercontent.com/JiongXing/MediaResources/master/PhotoBrowser"
        return (0..<8).map { index in
            XMJXGalleryItem(
                id: "jx-demo-\(index)",
                thumbnailURL: "\(baseURL)/photo_\(index)_thumbnail.png",
                originalURL: "\(baseURL)/photo_\(index).png"
            )
        }
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                CardContainer {
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text("JXPhotoBrowser UIKit 桥接验证")
                            .font(.headline)
                            .foregroundStyle(Color.textPrimary)

                        Text("点击任意缩略图进入浏览器，重点观察：Zoom 转场连续性、下滑关闭手感、关闭后缩略图显隐恢复。")
                            .font(.footnote)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Spacing.contentEdge)
                }

                XMJXImageWall(items: items, columnCount: 3, spacing: Spacing.half)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("JX 图片浏览器")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        JXPhotoBrowserTestView()
    }
}
#endif
