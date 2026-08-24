/**
 * [INPUT]: 依赖 BookshelfBookListCollectionItem、BookshelfBookListCollectionConfiguration 与 SwiftUI 行视图
 * [OUTPUT]: 对外提供二级书籍列表 collection cell、搜索 cell、section header 与空态承载视图
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
            message: emptyState.message,
            systemImage: emptyState.icon
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
        contentConfiguration = nil
    }

    /// 渲染当前 item。
    func configure(
        with item: BookshelfBookListCollectionItem,
        configuration: BookshelfBookListCollectionConfiguration,
        emptyPresentationMode: BookshelfBookListEmptyPresentationMode = .steadyEmptyUpdate
    ) {
        backgroundColor = .clear
        contentConfiguration = nil
        contentConfiguration = UIHostingConfiguration {
            switch item {
            case .searchDrawer:
                EmptyView()
            case .loading:
                BookshelfLoadingSkeletonView(
                    layoutMode: configuration.layoutMode,
                    columnCount: configuration.columnCount,
                    bottomContentInset: configuration.bottomContentInset,
                    accessibilityLabel: "正在整理书籍"
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: BookshelfBookListLayoutMetrics.loadingHeight)
            case .empty(let emptyState):
                BookshelfBookListEmptyStateContainer(
                    emptyState: emptyState,
                    presentationMode: emptyPresentationMode
                )
            case .book(let book):
                switch configuration.layoutMode {
                case .grid:
                    BookshelfBookListGridItemView(
                        book: book,
                        showsNoteCount: configuration.showsNoteCount,
                        sortCriteria: configuration.sortCriteria,
                        titleDisplayMode: configuration.titleDisplayMode,
                        searchKeyword: configuration.browseSearchKeyword,
                        isEditing: configuration.isEditing,
                        isSelected: configuration.selectedBookIDs.contains(book.id),
                        supportsContextPin: configuration.supportsContextPin,
                        activeWriteAction: configuration.activeWriteAction,
                        onContextAction: configuration.onContextAction
                    )
                case .list:
                    BookshelfBookListRowView(
                        book: book,
                        showsNoteCount: configuration.showsNoteCount,
                        sortCriteria: configuration.sortCriteria,
                        titleDisplayMode: configuration.titleDisplayMode,
                        searchKeyword: configuration.browseSearchKeyword,
                        isEditing: configuration.isEditing,
                        isSelected: configuration.selectedBookIDs.contains(book.id),
                        supportsContextPin: configuration.supportsContextPin,
                        activeWriteAction: configuration.activeWriteAction,
                        onContextAction: configuration.onContextAction
                    )
                }
            }
        }
        .margins(.all, 0)
    }
}
