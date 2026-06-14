/**
 * [INPUT]: 依赖 BookCollectionListItem、BookCollectionDetail、BookCollectionBookItem 与 XMBookCover 渲染书单列表、详情和书单内书籍关系
 * [OUTPUT]: 对外提供书单模块页面私有视觉组件，统一封面拼贴、指标、详情头、书籍卡片与推荐语区块
 * [POS]: Book 模块书单页面私有展示组件，被 BookCollectionListView、BookCollectionDetailView 与加入书单 Sheet 复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书单封面拼贴，以真实书籍封面建立书单识别，不复刻 Android 重渐变与遮罩。
struct BookCollectionCoverMosaicView: View {
    let covers: [String]
    var size: CGFloat = 82
    var tone: BookCollectionKind = .manual

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.surfaceCard)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                }

            if visibleCovers.isEmpty {
                placeholder
            } else {
                mosaic
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var visibleCovers: [String] {
        Array(covers.prefix(4))
    }

    private var coverWidth: CGFloat {
        max(24, size * 0.34)
    }

    private var placeholder: some View {
        VStack(spacing: Spacing.compact) {
            Image(systemName: tone == .annual ? "calendar" : "books.vertical")
                .font(AppTypography.title3)
                .foregroundStyle(Color.textHint)

            RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                .fill(Color.surfaceBorderSubtle)
                .frame(width: size * 0.34, height: Spacing.micro)
        }
    }

    private var mosaic: some View {
        ZStack {
            ForEach(Array(visibleCovers.enumerated()), id: \.offset) { index, cover in
                XMBookCover.fixedWidth(
                    coverWidth,
                    urlString: cover,
                    cornerRadius: CornerRadius.inlaySmall,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    placeholderIconSize: .small,
                    surfaceStyle: .spine
                )
                .rotationEffect(.degrees(rotation(for: index)))
                .offset(offset(for: index))
                .zIndex(Double(index))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.half)
        .clipped()
    }

    private func offset(for index: Int) -> CGSize {
        switch index {
        case 0:
            return CGSize(width: -size * 0.16, height: -size * 0.08)
        case 1:
            return CGSize(width: size * 0.08, height: -size * 0.12)
        case 2:
            return CGSize(width: -size * 0.06, height: size * 0.12)
        default:
            return CGSize(width: size * 0.18, height: size * 0.08)
        }
    }

    private func rotation(for index: Int) -> Double {
        switch index {
        case 0:
            return -5
        case 1:
            return 4
        case 2:
            return -2
        default:
            return 3
        }
    }
}

/// 书单封面横向陈列，用真实封面形成“被整理过的一组书”的集合感。
struct BookCollectionCoverShelfView: View {
    let covers: [String]
    var tone: BookCollectionKind = .manual

    private var visibleCovers: [String] {
        Array(covers.prefix(4))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.tight) {
            if visibleCovers.isEmpty {
                placeholder
            } else {
                ForEach(Array(visibleCovers.enumerated()), id: \.offset) { index, cover in
                    XMBookCover.fixedWidth(
                        index == 0 ? 58 : 50,
                        urlString: cover,
                        cornerRadius: CornerRadius.inlaySmall,
                        border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                        placeholderIconSize: .small,
                        surfaceStyle: .spine
                    )
                    .shadow(
                        color: Color.bookCoverDropShadow.opacity(index == 0 ? 0.70 : 0.42),
                        radius: index == 0 ? 6 : 4,
                        x: Spacing.none,
                        y: index == 0 ? 4 : 2
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        HStack(spacing: Spacing.cozy) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(index == 0 ? Color.surfaceNested : Color.controlFillSecondary.opacity(0.70))
                    .overlay {
                        if index == 0 {
                            Image(systemName: tone == .annual ? "calendar" : "books.vertical")
                                .font(AppTypography.callout)
                                .foregroundStyle(Color.textHint)
                        }
                    }
                    .frame(width: index == 0 ? 58 : 50, height: index == 0 ? 82 : 74)
            }
        }
    }
}

/// 书单指标条，用相邻小文本表达统计口径，避免模板化大数字指标卡。
struct BookCollectionMetricStrip: View {
    let bookCount: Int
    let finishedCount: Int
    let targetReadCount: Int?
    var layout: Layout = .inline

    enum Layout {
        case inline
        case compact
    }

    var body: some View {
        HStack(spacing: layout == .inline ? Spacing.base : Spacing.tight) {
            metric(value: "\(bookCount)", label: "本书")
            metric(value: "\(finishedCount)", label: "读完")

            if let targetReadCount, targetReadCount > 0 {
                metric(value: "\(finishedCount)/\(targetReadCount)", label: "目标")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.micro) {
            Text(value)
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(label)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textHint)
                .lineLimit(1)
        }
    }
}

/// 年度目标进度条，用轻量线性反馈表达读完目标，不引入榜单或社区化语义。
struct BookCollectionProgressMeter: View {
    let finishedCount: Int
    let targetReadCount: Int?

    var body: some View {
        if let targetReadCount, targetReadCount > 0 {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                ProgressView(
                    value: min(Double(finishedCount), Double(targetReadCount)),
                    total: Double(targetReadCount)
                )
                .progressViewStyle(.linear)
                .tint(Color.brandDeep.opacity(0.62))

                Text("读完 \(finishedCount)/\(targetReadCount) 本")
                    .font(AppTypography.caption2)
                    .foregroundStyle(Color.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("年度目标，读完 \(finishedCount) 本，共 \(targetReadCount) 本")
        }
    }
}

/// 书单列表卡片，建立封面、主题和统计之间的稳定层级。
struct BookCollectionListCard: View {
    let item: BookCollectionListItem

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.tight)

                BookCollectionStatusBadge(text: kindLabel, systemImage: kindIcon)
            }

            Text(subtitle)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            BookCollectionCoverShelfView(
                covers: item.representativeCovers,
                tone: item.kind
            )

            BookCollectionProgressMeter(
                finishedCount: item.finishedCount,
                targetReadCount: item.targetReadCount
            )

            HStack(alignment: .center, spacing: Spacing.tight) {
                BookCollectionMetricStrip(
                    bookCount: item.bookCount,
                    finishedCount: item.finishedCount,
                    targetReadCount: item.targetReadCount,
                    layout: .compact
                )

                Spacer(minLength: Spacing.tight)

                Label("查看书单", systemImage: "arrow.right")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, Spacing.tight)
                    .padding(.vertical, Spacing.cozy)
                    .background(Color.surfaceNested, in: Capsule())
            }
        }
        .padding(Spacing.section)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var title: String {
        if item.kind == .annual, let year = item.year, item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(year) 年阅读"
        }
        return item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书单" : item.title
    }

    private var subtitle: String {
        let description = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }
        switch item.kind {
        case .manual:
            return item.bookCount == 0 ? "还没有加入书籍。" : "按主题整理的个人书单。"
        case .annual:
            return item.targetReadCount == nil ? "随读完记录自动同步。" : "年度读完记录与目标进度。"
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .manual:
            return "我的整理"
        case .annual:
            return "年度同步"
        }
    }

    private var kindIcon: String {
        switch item.kind {
        case .manual:
            return "books.vertical"
        case .annual:
            return "calendar"
        }
    }

    private var accessibilityLabel: String {
        var parts = [title, item.kind == .annual ? "年度书单" : "我的书单", "\(item.bookCount)本书"]
        if item.finishedCount > 0 {
            parts.append("读完\(item.finishedCount)本")
        }
        if let target = item.targetReadCount, target > 0 {
            parts.append("年度目标\(item.finishedCount)/\(target)")
        }
        return parts.joined(separator: "，")
    }
}

/// 书单详情头，将书单主题、统计、只读边界和主动作集中在页面叙事层。
struct BookCollectionDetailHero: View {
    let detail: BookCollectionDetail
    let canPerformAction: Bool
    let onAddBook: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            HStack(alignment: .top, spacing: Spacing.base) {
                BookCollectionCoverMosaicView(
                    covers: detail.books.prefix(4).map(\.book.cover),
                    size: 106,
                    tone: detail.kind
                )

                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    BookCollectionStatusBadge(text: kindLabel, systemImage: kindIcon)

                    Text(title)
                        .font(AppTypography.title3Semibold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(description)
                        .font(AppTypography.callout)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    BookCollectionMetricStrip(
                        bookCount: detail.bookCount,
                        finishedCount: detail.finishedCount,
                        targetReadCount: detail.targetReadCount
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            BookCollectionProgressMeter(
                finishedCount: detail.finishedCount,
                targetReadCount: detail.targetReadCount
            )

            if detail.kind == .annual {
                BookCollectionReadOnlyNotice()
            } else {
                Button(action: onAddBook) {
                    Label("加入书籍", systemImage: "plus")
                        .font(AppTypography.subheadlineMedium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPerformAction)
            }
        }
        .padding(Spacing.section)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if detail.kind == .annual, let year = detail.year, detail.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(year) 年阅读"
        }
        return detail.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书单" : detail.title
    }

    private var description: String {
        let text = detail.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text
        }
        switch detail.kind {
        case .manual:
            return detail.bookCount == 0 ? "从书架里挑选几本书，给这个主题一个开始。" : "按你的阅读主题整理出的书籍集合。"
        case .annual:
            return "随读完记录自动同步，保留这一年的阅读轨迹。"
        }
    }

    private var kindLabel: String {
        switch detail.kind {
        case .manual:
            return "我的整理"
        case .annual:
            return "年度同步"
        }
    }

    private var kindIcon: String {
        switch detail.kind {
        case .manual:
            return "books.vertical"
        case .annual:
            return "lock"
        }
    }
}

/// 书单内书籍卡片，将书籍信息、阅读元数据和推荐语组织在同一关系单元内。
struct BookCollectionBookCard: View {
    let item: BookCollectionBookItem
    let isEditable: Bool
    let onOpen: () -> Void
    let onEditBook: () -> Void
    let onEditRecommend: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    XMBookCover.fixedWidth(
                        62,
                        urlString: item.book.cover,
                        cornerRadius: CornerRadius.inlaySmall,
                        border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                        placeholderIconSize: .small,
                        surfaceStyle: .spine
                    )

                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Text(item.book.title.isEmpty ? "未命名书籍" : item.book.title)
                            .font(AppTypography.subheadlineSemibold)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if !item.book.author.isEmpty {
                            Text(item.book.author)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }

                        if !metadataText.isEmpty {
                            Label(metadataText, systemImage: "bookmark")
                                .font(AppTypography.caption2)
                                .foregroundStyle(Color.textHint)
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption2Semibold)
                        .foregroundStyle(Color.textHint)
                        .padding(.top, Spacing.half)
                }

                if !trimmedRecommend.isEmpty {
                    BookCollectionRecommendQuote(
                        text: trimmedRecommend,
                        isEditable: isEditable,
                        onEdit: onEditRecommend
                    )
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle.opacity(0.55), lineWidth: CardStyle.borderWidth)
        }
        .contextMenu {
            Button {
                onOpen()
            } label: {
                XMMenuLabel("查看书籍", systemImage: "book")
            }

            Button {
                onEditBook()
            } label: {
                XMMenuLabel("编辑书籍", systemImage: "pencil")
            }

            Button {
                onEditRecommend()
            } label: {
                XMMenuLabel(item.recommend.isEmpty ? "添加推荐语" : "编辑推荐语", systemImage: "quote.bubble")
            }
            .disabled(!isEditable)

            if isEditable {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("移出书单", systemImage: "minus.circle")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isEditable {
                Button {
                    onEditRecommend()
                } label: {
                    Label("推荐语", systemImage: "quote.bubble")
                }
                .tint(.blue)

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("移出", systemImage: "minus.circle")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var metadataText: String {
        var parts: [String] = []
        if !item.book.readStatusBadgeTitle.isEmpty {
            parts.append(item.book.readStatusBadgeTitle)
        }
        if item.book.noteCount > 0 {
            parts.append("\(item.book.noteCount) 条书摘")
        }
        if !item.book.readingProgressText.isEmpty {
            parts.append(item.book.readingProgressText)
        }
        return parts.joined(separator: " · ")
    }

    private var trimmedRecommend: String {
        item.recommend.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var accessibilityLabel: String {
        var parts = [item.book.title.isEmpty ? "未命名书籍" : item.book.title]
        if !item.book.author.isEmpty {
            parts.append(item.book.author)
        }
        if !metadataText.isEmpty {
            parts.append(metadataText)
        }
        if !trimmedRecommend.isEmpty {
            parts.append("推荐语，\(trimmedRecommend)")
        } else if isEditable {
            parts.append("可添加推荐语")
        }
        return parts.joined(separator: "，")
    }
}

/// 推荐语区块，让 relation 的主观价值成为书单内容，而不是行内弱说明。
struct BookCollectionRecommendQuote: View {
    let text: String
    let isEditable: Bool
    let onEdit: () -> Void

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        Button(action: onEdit) {
            HStack(alignment: .top, spacing: Spacing.tight) {
                RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                    .fill(Color.brand.opacity(0.18))
                    .frame(width: 3, height: 34)

                Text(trimmed)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.compact)

                if isEditable {
                    Image(systemName: "pencil")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textHint)
                }
            }
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, Spacing.cozy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceNested.opacity(0.82), in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .accessibilityLabel("推荐语，\(trimmed)")
    }
}

/// 书单状态徽标，限定在书单列表与详情头的小型语义说明。
struct BookCollectionStatusBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(AppTypography.caption2Medium)
            .foregroundStyle(Color.textSecondary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.micro)
            .background(Color.surfaceNested, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// 年度书单只读说明，放在详情头内，避免页面中部重复占位。
private struct BookCollectionReadOnlyNotice: View {
    var body: some View {
        Label("年度书单只读，随读完记录同步。", systemImage: "lock")
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, Spacing.cozy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
    }
}

/// 书单首页读取占位，保持首屏结构稳定，避免列表加载时出现空白内容区。
struct BookCollectionListSkeletonRows: View {
    var body: some View {
        VStack(spacing: Spacing.base) {
            ForEach(0..<3, id: \.self) { _ in
                BookCollectionListSkeletonCard()
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.half)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}

/// 书单详情读取占位，承接顶部栏下方内容，避免导航转场时露出纯空白页。
struct BookCollectionDetailSkeletonContent: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                BookCollectionDetailSkeletonHero()
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.base)

                ForEach(0..<4, id: \.self) { _ in
                    BookCollectionBookSkeletonCard()
                        .padding(.horizontal, Spacing.screenEdge)
                }
            }
            .padding(.bottom, Spacing.double)
        }
        .scrollIndicators(.hidden)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}

struct BookCollectionListSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(Color.surfaceNested)
                .frame(width: 168, height: 18)

            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(Color.surfaceNested)
                .frame(width: 220, height: 14)

            HStack(spacing: Spacing.tight) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                        .fill(Color.surfaceNested)
                        .frame(width: index == 0 ? 58 : 50, height: index == 0 ? 82 : 74)
                }
            }

            RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                .fill(Color.surfaceNested)
                .frame(height: 34)
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
    }
}

private struct BookCollectionDetailSkeletonHero: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.surfaceNested)
                .frame(width: 106, height: 106)

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 82, height: 22)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 176, height: 20)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 210, height: 14)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 148, height: 14)
            }
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
    }
}

private struct BookCollectionBookSkeletonCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(Color.surfaceNested)
                .frame(width: 62, height: 88)

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 190, height: 18)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 132, height: 14)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 112, height: 12)
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
    }
}
