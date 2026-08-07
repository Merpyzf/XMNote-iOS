import SwiftUI

/**
 * [INPUT]: 依赖 SwiftUI LazyVGrid 布局、XMJXThumbnailView 缩略图桥接与 XMJXPhotoBrowserPresenter 浏览器桥接器
 * [OUTPUT]: 对外提供 XMJXImageWall（JX 图片墙组件）
 * [POS]: UIComponents/GalleryJX 的 SwiftUI 展示入口，负责宫格渲染与浏览器触发，并强持有 Presenter 避免 weak delegate 被提前释放
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// JX 图片墙 SwiftUI 入口，负责宫格缩略图布局与全屏浏览器唤起。
struct XMJXImageWall: View {
    let items: [XMJXGalleryItem]
    let columnCount: Int
    let spacing: CGFloat
    let priority: XMImageRequestBuilder.Priority

    @State private var host: XMJXPhotoBrowserHost
    @State private var tapSequence: Int = 0
    @State private var wallID: String = UUID().uuidString

    /// 初始化图片墙参数。
    init(
        items: [XMJXGalleryItem],
        columnCount: Int = 3,
        spacing: CGFloat = 6,
        priority: XMImageRequestBuilder.Priority = .high
    ) {
        self.items = items
        self.columnCount = max(1, columnCount)
        self.spacing = spacing
        self.priority = priority
        _host = State(initialValue: XMJXPhotoBrowserHost(initialItems: items))
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                XMJXThumbnailView(item: item, registry: host.registry, priority: priority)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                        .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
                )
                .onTapGesture {
                    tapSequence += 1
                    host.open(at: index, wallID: wallID, tapSequence: tapSequence)
                }
            }
        }
        .task {
            host.updateItems(items)
        }
        .onChange(of: items) { _, newValue in
            host.updateItems(newValue)
        }
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: columnCount
        )
    }
}
