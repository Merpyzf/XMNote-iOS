/**
 * [INPUT]: 依赖 BookshelfBookListCollectionItem、BookshelfBookListCollectionConfiguration、UIContentConfiguration 与 SwiftUI 行视图
 * [OUTPUT]: 对外提供带确定性 SwiftUI Cell 配置的二级书籍列表 collection cell、搜索 cell、section header 与空态承载视图
 * [POS]: Book 模块二级书籍列表页面私有 cell 组件，隔离 UICollectionView cell 渲染细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 二级列表搜索 surface，作为 collection 顶部唯一检索入口承载折叠态和输入态。
final class BookshelfBookListSearchCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfBookListSearchCell"
    private let searchSurface = BookshelfSearchSurfaceView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        searchSurface.prepareForReuse()
    }

    /// 同步搜索 surface 的折叠/输入状态；关键词回写由闭包交给 ViewModel。
    func configure(with configuration: BookshelfBookListCollectionConfiguration) {
        searchSurface.configure(with: BookshelfSearchSurfaceConfiguration(
            namespace: "bookshelf.book-list.search",
            placeholder: configuration.browseSearchPlaceholder,
            keyword: configuration.browseSearchText,
            showsInput: configuration.showsExpandedSearchSurface,
            showsClearAction: configuration.hasBrowseSearchText || configuration.hasBrowseSearchKeyword,
            usesAccessibilityLayout: configuration.searchDrawerHeight > BookshelfBookListChromeMetrics.normalSearchAreaHeight,
            isFocused: configuration.isBrowseSearchFocused,
            focusTrigger: configuration.browseSearchFocusTrigger,
            accessibilityLabel: configuration.browseSearchPlaceholder,
            onActivate: configuration.onActivateBrowseSearch,
            onTextChange: configuration.onBrowseSearchKeywordChange,
            onSubmit: configuration.onSubmitBrowseSearch,
            onClear: configuration.onClearBrowseSearch,
            onCancel: configuration.onCollapseBrowseSearch,
            onFocusChange: configuration.onBrowseSearchFocusChange
        ))
    }

    private func setupViewHierarchy() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        searchSurface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(searchSurface)
        NSLayoutConstraint.activate([
            searchSurface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.screenEdge),
            searchSurface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.screenEdge),
            searchSurface.topAnchor.constraint(equalTo: contentView.topAnchor),
            searchSurface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }
}

/// 二级列表分区标题。
final class BookshelfBookListSectionHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "BookshelfBookListSectionHeaderView"
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 渲染当前分区标题。
    func configure(title: String) {
        titleLabel.text = title
    }

    private func setupViewHierarchy() {
        backgroundColor = .clear
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.tiny),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.tiny),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.tiny),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.tiny)
        ])
    }
}

/// 二级列表空态的进场承载层，避免搜索结果区从网格硬切到占位。
struct BookshelfBookListEmptyStateContainer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let emptyState: BookshelfBookListEmptyState
    let presentationMode: BookshelfBookListEmptyPresentationMode
    @State private var isVisible: Bool

    init(
        emptyState: BookshelfBookListEmptyState,
        presentationMode: BookshelfBookListEmptyPresentationMode
    ) {
        self.emptyState = emptyState
        self.presentationMode = presentationMode
        _isVisible = State(initialValue: presentationMode == .steadyEmptyUpdate)
    }

    var body: some View {
        XMContentStateView(
            role: emptyState.stateRole,
            title: emptyState.title,
            message: emptyState.message
        )
        .frame(maxWidth: .infinity)
        .frame(minHeight: BookshelfBookListLayoutMetrics.emptyHeight)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(shouldUseSpatialEntrance && !isVisible ? 0.985 : 1)
        .offset(y: shouldUseSpatialEntrance && !isVisible ? 8 : 0)
        .onAppear {
            guard !isVisible else { return }
            guard presentationMode == .enteringFromContent else {
                isVisible = true
                return
            }
            withAnimation(BookshelfManagementMotion.bookListResultStateAnimation(reduceMotion: reduceMotion)) {
                isVisible = true
            }
        }
    }

    private var shouldUseSpatialEntrance: Bool {
        presentationMode == .enteringFromContent && !reduceMotion
    }
}

/// 二级列表 cell，使用 UIHostingConfiguration 复用 SwiftUI 行视觉。
final class BookshelfBookListCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfBookListCollectionCell"
    private var hostedContentView: (UIView & UIContentView)?
    private var renderedIdentity: BookshelfBookListCollectionCellRenderIdentity?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        renderedIdentity = nil
        hostedContentView?.isHidden = true
        hostedContentView?.accessibilityElementsHidden = true
        hostedContentView?.layer.removeAllAnimations()
        layer.removeAllAnimations()
        alpha = 1
        transform = .identity
    }

    /// 渲染当前 item。
    func configure(
        with item: BookshelfBookListCollectionItem,
        configuration: BookshelfBookListCollectionConfiguration,
        emptyPresentationMode: BookshelfBookListEmptyPresentationMode = .steadyEmptyUpdate
    ) {
        backgroundColor = .clear
        let snapshot = BookshelfBookListCollectionCellRenderSnapshot(
            item: item,
            layoutMode: configuration.layoutMode,
            columnCount: configuration.columnCount,
            bottomContentInset: configuration.bottomContentInset,
            showsNoteCount: configuration.showsNoteCount,
            sortCriteria: configuration.sortCriteria,
            titleDisplayMode: configuration.titleDisplayMode,
            searchKeyword: configuration.browseSearchKeyword,
            isEditing: configuration.isEditing,
            isSelected: item.bookID.map(configuration.selectedBookIDs.contains) ?? false,
            supportsContextPin: configuration.supportsContextPin,
            activeWriteAction: configuration.activeWriteAction,
            emptyPresentationMode: emptyPresentationMode
        )
        let didChangeIdentity = renderedIdentity != nil && renderedIdentity != snapshot.identity
        renderedIdentity = snapshot.identity

        let hostingConfiguration = UIHostingConfiguration {
            BookshelfBookListCollectionCellContent(
                snapshot: snapshot,
                onContextAction: configuration.onContextAction
            )
            .id(snapshot.identity)
        }
        .margins(.all, 0)

        apply(hostingConfiguration)
        if didChangeIdentity {
            hostedContentView?.layer.removeAllAnimations()
        }
    }

    /// 优先更新现有内容视图；配置类型不兼容时才重建宿主，保证每次输入都有显式刷新出口。
    private func apply<Configuration: UIContentConfiguration>(_ configuration: Configuration) {
        if let hostedContentView, hostedContentView.supports(configuration) {
            hostedContentView.configuration = configuration
            hostedContentView.isHidden = false
            hostedContentView.accessibilityElementsHidden = false
            return
        }

        hostedContentView?.removeFromSuperview()
        let contentView = configuration.makeContentView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = .clear
        hostedContentView = contentView
        self.contentView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: self.contentView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor)
        ])
    }
}

/// 二级书籍 cell 的业务身份只随内容类型或书籍 ID 改变，选择和整理状态不会重置 SwiftUI 身份。
private enum BookshelfBookListCollectionCellRenderIdentity: Hashable {
    case searchDrawer
    case loading
    case empty
    case book(Int64)
}

/// 二级书籍 cell 的完整值快照；仅携带当前条目实际消费的展示字段。
private struct BookshelfBookListCollectionCellRenderSnapshot: Hashable {
    let item: BookshelfBookListCollectionItem
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let bottomContentInset: CGFloat
    let showsNoteCount: Bool
    let sortCriteria: BookshelfSortCriteria
    let titleDisplayMode: BookshelfTitleDisplayMode
    let searchKeyword: String
    let isEditing: Bool
    let isSelected: Bool
    let supportsContextPin: Bool
    let activeWriteAction: BookshelfBookListEditAction?
    let emptyPresentationMode: BookshelfBookListEmptyPresentationMode

    var identity: BookshelfBookListCollectionCellRenderIdentity {
        switch item {
        case .searchDrawer:
            return .searchDrawer
        case .loading:
            return .loading
        case .empty:
            return .empty
        case .book(let book):
            return .book(book.id)
        }
    }
}

/// 使用值快照生成二级书籍 cell 内容，视觉与可访问性始终读取同一个 isSelected。
private struct BookshelfBookListCollectionCellContent: View {
    let snapshot: BookshelfBookListCollectionCellRenderSnapshot
    let onContextAction: (BookshelfBookContextAction, Int64) -> Void

    @ViewBuilder
    var body: some View {
        switch snapshot.item {
        case .searchDrawer:
            EmptyView()
        case .loading:
            BookshelfLoadingSkeletonView(
                layoutMode: snapshot.layoutMode,
                columnCount: snapshot.columnCount,
                bottomContentInset: snapshot.bottomContentInset,
                accessibilityLabel: "正在整理书籍"
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: BookshelfBookListLayoutMetrics.loadingHeight)
        case .empty(let emptyState):
            BookshelfBookListEmptyStateContainer(
                emptyState: emptyState,
                presentationMode: snapshot.emptyPresentationMode
            )
        case .book(let book):
            switch snapshot.layoutMode {
            case .grid:
                BookshelfBookListGridItemView(
                    book: book,
                    showsNoteCount: snapshot.showsNoteCount,
                    sortCriteria: snapshot.sortCriteria,
                    titleDisplayMode: snapshot.titleDisplayMode,
                    searchKeyword: snapshot.searchKeyword,
                    isEditing: snapshot.isEditing,
                    isSelected: snapshot.isSelected,
                    supportsContextPin: snapshot.supportsContextPin,
                    activeWriteAction: snapshot.activeWriteAction,
                    onContextAction: onContextAction
                )
            case .list:
                BookshelfBookListRowView(
                    book: book,
                    showsNoteCount: snapshot.showsNoteCount,
                    sortCriteria: snapshot.sortCriteria,
                    titleDisplayMode: snapshot.titleDisplayMode,
                    searchKeyword: snapshot.searchKeyword,
                    isEditing: snapshot.isEditing,
                    isSelected: snapshot.isSelected,
                    supportsContextPin: snapshot.supportsContextPin,
                    activeWriteAction: snapshot.activeWriteAction,
                    onContextAction: onContextAction
                )
            }
        }
    }
}

private extension BookshelfBookListCollectionItem {
    var bookID: Int64? {
        guard case .book(let book) = self else { return nil }
        return book.id
    }
}
