//
//  BookshelfBookListView.swift
//  xmnote
//
//  Created by Codex on 2026/5/6.
//

/**
 * [INPUT]: 依赖 BookshelfBookListRoute 提供只读聚合列表载荷，依赖外层 BookRoute 闭包承接书籍详情导航
 * [OUTPUT]: 对外提供 BookshelfBookListView，使用 UIKit UICollectionView 展示分组、状态、标签、来源、评分与作者聚合下的书籍列表
 * [POS]: Book 模块二级只读列表页，被 BookRoute.bookshelfList 导航目标消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书架聚合入口的二级只读列表页，只消费上级快照裁剪出的展示载荷，不直接访问数据库。
struct BookshelfBookListView: View {
    let route: BookshelfBookListRoute
    let onOpenRoute: (BookRoute) -> Void

    /// 构建二级书籍列表；点击书籍时把导航意图交回外层 NavigationStack。
    init(
        route: BookshelfBookListRoute,
        onOpenRoute: @escaping (BookRoute) -> Void = { _ in }
    ) {
        self.route = route
        self.onOpenRoute = onOpenRoute
    }

    var body: some View {
        BookshelfBookListCollectionView(
            route: route,
            onOpenBook: { bookID in
                onOpenRoute(.detail(bookId: bookID))
            }
        )
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 二级书籍列表 UIKit 集合区，负责滚动、空态和行点击命中。
private struct BookshelfBookListCollectionView: UIViewRepresentable {
    let route: BookshelfBookListRoute
    let onOpenBook: (Int64) -> Void

    /// 创建 collection view 承载视图。
    func makeUIView(context: Context) -> BookshelfBookListCollectionHostView {
        let view = BookshelfBookListCollectionHostView()
        view.update(with: configuration, animated: false)
        return view
    }

    /// 同步最新路由载荷。
    func updateUIView(_ uiView: BookshelfBookListCollectionHostView, context: Context) {
        uiView.update(with: configuration, animated: true)
    }

    private var configuration: BookshelfBookListCollectionConfiguration {
        BookshelfBookListCollectionConfiguration(
            route: route,
            onOpenBook: onOpenBook
        )
    }
}

/// UIKit 集合区输入配置。
private struct BookshelfBookListCollectionConfiguration {
    let route: BookshelfBookListRoute
    let onOpenBook: (Int64) -> Void

    static let empty = BookshelfBookListCollectionConfiguration(
        route: BookshelfBookListRoute(title: "", subtitle: "", books: []),
        onOpenBook: { _ in }
    )
}

/// 二级书籍列表 item 类型，把 subtitle、empty 与书籍行统一交给 collection view 管理。
private enum BookshelfBookListCollectionItem: Hashable {
    case subtitle(String)
    case empty
    case book(BookshelfBookListItem)
}

/// UICollectionView 承载视图，负责单列布局和行点击。
private final class BookshelfBookListCollectionHostView: UIView {
    private var configuration = BookshelfBookListCollectionConfiguration.empty
    private var items: [BookshelfBookListCollectionItem] = []

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .automatic
        view.keyboardDismissMode = .onDrag
        view.dataSource = self
        view.delegate = self
        view.register(
            BookshelfBookListCollectionCell.self,
            forCellWithReuseIdentifier: BookshelfBookListCollectionCell.reuseIdentifier
        )
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 同步 SwiftUI 路由载荷到本地 item 列表。
    func update(
        with configuration: BookshelfBookListCollectionConfiguration,
        animated: Bool
    ) {
        let nextItems = Self.makeItems(from: configuration.route)
        self.configuration = configuration
        guard nextItems != items else {
            refreshVisibleCells()
            return
        }
        items = nextItems
        collectionView.reloadData()
    }
}

private extension BookshelfBookListCollectionHostView {
    /// 建立 collection view 约束。
    func setupViewHierarchy() {
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "bookshelf.book-list.collection"

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// 使用单列估算高度布局，让 SwiftUI row 自适应文本高度。
    func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(92)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(92)
            )
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = Spacing.base
            section.contentInsets = NSDirectionalEdgeInsets(
                top: Spacing.base,
                leading: Spacing.screenEdge,
                bottom: Spacing.base,
                trailing: Spacing.screenEdge
            )
            return section
        }
    }

    /// 根据路由载荷生成 collection item。
    static func makeItems(from route: BookshelfBookListRoute) -> [BookshelfBookListCollectionItem] {
        var nextItems: [BookshelfBookListCollectionItem] = []
        if !route.subtitle.isEmpty {
            nextItems.append(.subtitle(route.subtitle))
        }
        if route.books.isEmpty {
            nextItems.append(.empty)
        } else {
            nextItems.append(contentsOf: route.books.map(BookshelfBookListCollectionItem.book))
        }
        return nextItems
    }

    /// 刷新可见 cell 中的闭包和选中态，不触发布局重载。
    func refreshVisibleCells() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? BookshelfBookListCollectionCell,
                  items.indices.contains(indexPath.item) else {
                continue
            }
            cell.configure(with: items[indexPath.item])
        }
    }
}

extension BookshelfBookListCollectionHostView: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BookshelfBookListCollectionCell.reuseIdentifier,
            for: indexPath
        ) as? BookshelfBookListCollectionCell else {
            return UICollectionViewCell()
        }
        cell.configure(with: items[indexPath.item])
        return cell
    }
}

extension BookshelfBookListCollectionHostView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard items.indices.contains(indexPath.item) else { return }
        if case .book(let book) = items[indexPath.item] {
            configuration.onOpenBook(book.id)
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard items.indices.contains(indexPath.item) else { return false }
        if case .book = items[indexPath.item] {
            return true
        }
        return false
    }
}

/// 二级列表 cell，使用 UIHostingConfiguration 复用 SwiftUI 行视觉。
private final class BookshelfBookListCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfBookListCollectionCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 渲染当前 item。
    func configure(with item: BookshelfBookListCollectionItem) {
        backgroundColor = .clear
        contentConfiguration = UIHostingConfiguration {
            switch item {
            case .subtitle(let subtitle):
                BookshelfBookListSubtitleView(subtitle: subtitle)
            case .empty:
                EmptyStateView(icon: "books.vertical", message: "暂无书籍")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 320)
            case .book(let book):
                BookshelfBookListRowView(book: book)
            }
        }
        .margins(.all, 0)
    }
}

/// 二级列表副标题。
private struct BookshelfBookListSubtitleView: View {
    let subtitle: String

    var body: some View {
        Text(subtitle)
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.tiny)
    }
}

/// 二级列表书籍行视觉。
private struct BookshelfBookListRowView: View {
    let book: BookshelfBookListItem

    var body: some View {
        HStack(spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                48,
                urlString: book.cover,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(book.title)
                    .font(AppTypography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                Text(metadata)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.compact)

            Image(systemName: "chevron.right")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title)，\(metadata)")
        .accessibilityAddTraits(.isButton)
    }

    private var metadata: String {
        let authorText = book.author.isEmpty ? "未知作者" : book.author
        guard book.noteCount > 0 else { return authorText }
        return "\(authorText) · \(book.noteCount)条书摘"
    }
}

#Preview {
    NavigationStack {
        BookshelfBookListView(route: BookshelfBookListRoute(
            title: "文学",
            subtitle: "2本",
            books: [
                BookshelfBookListItem(id: 1, title: "月亮与六便士", author: "毛姆", cover: "", noteCount: 12),
                BookshelfBookListItem(id: 2, title: "长日将尽", author: "石黑一雄", cover: "", noteCount: 3)
            ]
        ))
    }
}
