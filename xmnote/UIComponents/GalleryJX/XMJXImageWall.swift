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

    @State private var host: XMJXPhotoBrowserHost
    @State private var tapSequence: Int = 0
    @State private var wallID: String = UUID().uuidString

    /// 初始化图片墙参数。
    init(
        items: [XMJXGalleryItem],
        columnCount: Int = 3,
        spacing: CGFloat = 6
    ) {
        self.items = items
        self.columnCount = max(1, columnCount)
        self.spacing = spacing
        _host = State(initialValue: XMJXPhotoBrowserHost(initialItems: items))
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                ZStack {
                    XMJXThumbnailView(item: item, registry: host.registry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .contentShape(Rectangle())
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                XMJXGalleryLogger.verbose(
                                    "cell.frame wallID=\(wallID) index=\(index) itemID=\(item.id) frame=\(describe(proxy.size))"
                                )
                            }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                        .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
                )
                .overlay {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                SpatialTapGesture()
                                    .onEnded { value in
                                        tapSequence += 1
                                        XMJXGalleryLogger.essential(
                                            "tap.received wallID=\(wallID) tapSeq=\(tapSequence) index=\(index) itemID=\(item.id) itemsCount=\(items.count) location=\(describe(value.location)) cell=\(describe(proxy.size))"
                                        )
                                        host.open(at: index, wallID: wallID, tapSequence: tapSequence)
                                    }
                            )
                            .onAppear {
                                XMJXGalleryLogger.verbose(
                                    "tap.overlay.ready wallID=\(wallID) index=\(index) itemID=\(item.id) frame=\(describe(proxy.size))"
                                )
                            }
                    }
                }
            }
        }
        .onAppear {
            XMJXGalleryLogger.verbose("tap.hitTest.config wallID=\(wallID) contentShape=Rectangle")
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

@MainActor
private final class XMJXPhotoBrowserHost {
    let registry = XMJXThumbnailRegistry()

    private var presenter: XMJXPhotoBrowserPresenter?
    private var currentItems: [XMJXGalleryItem]

    init(initialItems: [XMJXGalleryItem]) {
        self.currentItems = initialItems
        if !initialItems.isEmpty {
            self.presenter = XMJXPhotoBrowserPresenter(items: initialItems, registry: registry)
        }
        XMJXGalleryLogger.verbose(
            "host.init itemsCount=\(initialItems.count) presenterReady=\(presenter != nil)"
        )
    }

    /// 同步图片墙数据源到浏览器桥接器。
    func updateItems(_ items: [XMJXGalleryItem]) {
        XMJXGalleryLogger.verbose("host.updateItems.begin itemsCount=\(items.count) presenterReady=\(presenter != nil)")
        currentItems = items
        if let presenter {
            presenter.updateItems(items)
        } else if !items.isEmpty {
            presenter = XMJXPhotoBrowserPresenter(items: items, registry: registry)
        }
        XMJXGalleryLogger.verbose("host.updateItems.end itemsCount=\(items.count) presenterReady=\(presenter != nil)")
    }

    /// 打开指定索引的浏览器全屏页。
    func open(at index: Int, wallID: String, tapSequence: Int) {
        XMJXGalleryLogger.essential(
            "host.open.begin wallID=\(wallID) tapSeq=\(tapSequence) index=\(index) itemsCount=\(currentItems.count) presenterReady=\(presenter != nil)"
        )

        guard !currentItems.isEmpty else {
            XMJXGalleryLogger.essential("host.open.abort wallID=\(wallID) tapSeq=\(tapSequence) reason=emptyItems")
            return
        }
        guard currentItems.indices.contains(index) else {
            XMJXGalleryLogger.essential("host.open.abort wallID=\(wallID) tapSeq=\(tapSequence) reason=indexOutOfRange")
            return
        }
        if presenter == nil {
            presenter = XMJXPhotoBrowserPresenter(items: currentItems, registry: registry)
            XMJXGalleryLogger.essential("host.open.preparePresenter wallID=\(wallID) tapSeq=\(tapSequence) created=true")
        }
        guard let presenter else {
            XMJXGalleryLogger.essential("host.open.abort wallID=\(wallID) tapSeq=\(tapSequence) reason=presenterMissing")
            return
        }

        let itemID = currentItems[index].id
        XMJXGalleryLogger.essential(
            "host.open.callPresenter wallID=\(wallID) tapSeq=\(tapSequence) index=\(index) itemID=\(itemID)"
        )
        presenter.present(initialIndex: index, wallID: wallID, tapSequence: tapSequence)
    }
}

private extension XMJXImageWall {
    /// 把尺寸转换为日志友好的紧凑文本，便于排查命中区域和布局异常。
    func describe(_ size: CGSize) -> String {
        "w=\(Int(size.width.rounded())) h=\(Int(size.height.rounded()))"
    }

    /// 把点击坐标转换为日志文本，便于核对手势命中位置。
    func describe(_ point: CGPoint) -> String {
        "x=\(Int(point.x.rounded())) y=\(Int(point.y.rounded()))"
    }
}
