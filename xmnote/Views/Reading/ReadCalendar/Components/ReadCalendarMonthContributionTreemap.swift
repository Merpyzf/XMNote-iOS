import SwiftUI

/**
 * [INPUT]: 依赖年度月份贡献数据、月份点击回调与阅读日历月份渐变及统计排版令牌
 * [OUTPUT]: 对外提供 ReadCalendarMonthContributionTreemap 加权树图
 * [POS]: 阅读日历年度统计 Sheet 的页面私有分布组件，按阅读时长面积展示可访问月份并支持下钻
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 年度月份贡献加权树图，面积严格跟随阅读时长占比并使用确定性布局。
struct ReadCalendarMonthContributionTreemap: View {
    /// Item 是树图所需的最小月份快照，避免组件依赖完整年度 Sheet 状态。
    struct Item: Identifiable, Hashable {
        let monthStart: Date
        let activeDays: Int
        let totalReadSeconds: Int

        var id: Date { monthStart }
    }

    private struct Tile: Identifiable {
        let item: Item
        let frame: CGRect

        var id: Date { item.id }
    }

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let items: [Item]
    let onMonthTap: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("年度阅读分布")
                .font(ReadCalendarSummaryTypography.sectionTitle)
                .foregroundStyle(Color.textPrimary)

            if visibleItems.isEmpty {
                Text("暂无阅读分布")
                    .font(ReadCalendarSummaryTypography.insightMeta)
                    .foregroundStyle(Color.textHint)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else {
                GeometryReader { proxy in
                    let bounds = CGRect(origin: .zero, size: proxy.size)
                    let tiles = layout(items: visibleItems, in: bounds)

                    ForEach(tiles) { tile in
                        tileButton(tile)
                    }
                }
                .frame(height: treeHeight)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
                .transition(accessibilityReduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }
}

private extension ReadCalendarMonthContributionTreemap {
    enum TileLabelLevel {
        case full
        case medium
        case compact
        case monthOnly
        case none
    }

    var visibleItems: [Item] {
        let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return items
            .filter { $0.totalReadSeconds > 0 && $0.monthStart <= currentMonth }
            .sorted {
                if $0.totalReadSeconds == $1.totalReadSeconds {
                    return $0.monthStart < $1.monthStart
                }
                return $0.totalReadSeconds > $1.totalReadSeconds
            }
    }

    var treeHeight: CGFloat {
        switch visibleItems.count {
        case 0: 92
        case 1: 140
        case 2...3: 188
        default: 220
        }
    }

    var totalDuration: Int {
        max(1, visibleItems.reduce(0) { $0 + $1.totalReadSeconds })
    }

    /// 使用按权重二分的确定性布局；每次沿长边切割，保证面积与年度时长占比一致。
    private func layout(items: [Item], in frame: CGRect) -> [Tile] {
        guard let first = items.first else { return [] }
        guard items.count > 1 else { return [Tile(item: first, frame: inset(frame))] }

        let total = items.reduce(0) { $0 + $1.totalReadSeconds }
        guard total > 0 else { return [] }

        let splitIndex = balancedSplitIndex(items: items, total: total)
        let leadingItems = Array(items[..<splitIndex])
        let trailingItems = Array(items[splitIndex...])
        let leadingWeight = leadingItems.reduce(0) { $0 + $1.totalReadSeconds }
        let ratio = CGFloat(leadingWeight) / CGFloat(total)

        let leadingFrame: CGRect
        let trailingFrame: CGRect
        if frame.width >= frame.height {
            let leadingWidth = frame.width * ratio
            leadingFrame = CGRect(x: frame.minX, y: frame.minY, width: leadingWidth, height: frame.height)
            trailingFrame = CGRect(x: frame.minX + leadingWidth, y: frame.minY, width: frame.width - leadingWidth, height: frame.height)
        } else {
            let leadingHeight = frame.height * ratio
            leadingFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: leadingHeight)
            trailingFrame = CGRect(x: frame.minX, y: frame.minY + leadingHeight, width: frame.width, height: frame.height - leadingHeight)
        }

        return layout(items: leadingItems, in: leadingFrame) + layout(items: trailingItems, in: trailingFrame)
    }

    /// 找到最接近总权重一半且不会产生空分区的切点。
    func balancedSplitIndex(items: [Item], total: Int) -> Int {
        var prefix = 0
        var bestIndex = 1
        var bestDistance = Int.max
        for index in 1..<items.count {
            prefix += items[index - 1].totalReadSeconds
            let distance = abs(total - prefix * 2)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// 给相邻月份保留细缝，同时避免极小矩形被负尺寸吞掉。
    func inset(_ frame: CGRect) -> CGRect {
        let inset = min(1.5, min(frame.width / 6, frame.height / 6))
        return frame.insetBy(dx: inset, dy: inset)
    }

    /// 月份卡片根据可用面积依次降级标签，点击后沿用现有 Sheet 下钻路径。
    private func tileButton(_ tile: Tile) -> some View {
        let month = calendar.component(.month, from: tile.item.monthStart)
        let percent = min(100, max(1, Int((Double(tile.item.totalReadSeconds) / Double(totalDuration) * 100).rounded())))
        let gradient = Color.readCalendarMonthContributionGradientSpec(for: month)
        let shape = RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)

        return Button {
            onMonthTap(tile.item.monthStart)
        } label: {
            tileLabel(
                item: tile.item,
                month: month,
                percent: percent,
                isSingle: visibleItems.count == 1
            )
                .frame(width: tile.frame.width, height: tile.frame.height, alignment: .topLeading)
                .background {
                    LinearGradient(
                        colors: [gradient.start, gradient.mid, gradient.end],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.04),
                            Color.white.opacity(0.32),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 2)
                }
                .overlay {
                    shape.strokeBorder(
                        Color.white.opacity(0.20),
                        lineWidth: CardStyle.borderWidth
                    )
                }
                .compositingGroup()
                .clipShape(shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .position(x: tile.frame.midX, y: tile.frame.midY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(month)月，占全年\(percent)%，阅读\(durationText(tile.item.totalReadSeconds))，活跃\(tile.item.activeDays)天"
        )
        .accessibilityHint("打开该月阅读总结")
    }

    /// 使用最终渲染文本的固有尺寸选择标签层级，空间不足时不创建可见裁切兜底。
    func tileLabel(item: Item, month: Int, percent: Int, isSingle: Bool) -> some View {
        ReadCalendarTreemapTileLabelLayout(isSingle: isSingle) {
            Text("\(month)月")
                .font(ReadCalendarSummaryTypography.treemapMonth)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .fixedSize()

            Text("\(percent)%")
                .font(ReadCalendarSummaryTypography.treemapPercent)
                .foregroundStyle(Color.white.opacity(0.84))
                .lineLimit(1)
                .fixedSize()

            Text(durationText(item.totalReadSeconds))
                .font(ReadCalendarSummaryTypography.treemapDetail)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .fixedSize()

            Text("活跃 \(item.activeDays) 天")
                .font(ReadCalendarSummaryTypography.treemapDetail)
                .foregroundStyle(Color.white.opacity(0.76))
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityHidden(true)
    }

    /// 将秒数格式化为紧凑时长文案，服务树图标签与无障碍读法。
    func durationText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时"
        }
        if minutes > 0 {
            return "\(minutes)分"
        }
        return "\(max(1, seconds))秒"
    }
}

/// 树图标签布局使用实际 Text 子视图尺寸逐级降级，保证任何可见内容都不会依赖裁切或缩放。
private struct ReadCalendarTreemapTileLabelLayout: Layout {
    let isSingle: Bool

    private let gap: CGFloat = 4

    /// 返回父级给定的树图块尺寸，标签本身不反向改变权重布局。
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(
            width: max(proposal.width ?? 0, 0),
            height: max(proposal.height ?? 0, 0)
        )
    }

    /// 在同一次布局中完成固有尺寸测量与摆放，并把未选中的子视图显式移出裁切区域。
    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 4 else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let level = labelLevel(for: bounds.size, textSizes: sizes)

        switch level {
        case .full:
            placeTopRow(in: bounds, padding: desiredPadding, sizes: sizes, subviews: subviews)
            placeBottomDetails(in: bounds, padding: desiredPadding, sizes: sizes, subviews: subviews)
            hideUnusedSubviews(in: subviews, visibleIndices: [0, 1, 2, 3], outside: bounds, sizes: sizes)
        case .medium:
            placeTopRow(in: bounds, padding: 8, sizes: sizes, subviews: subviews)
            place(
                subviews[2],
                at: CGPoint(x: bounds.minX + 8, y: bounds.maxY - 8 - sizes[2].height),
                size: sizes[2]
            )
            hideUnusedSubviews(in: subviews, visibleIndices: [0, 1, 2], outside: bounds, sizes: sizes)
        case .compact:
            let padding = CGSize(width: 8, height: 6)
            let contentHeight = sizes[0].height + sizes[1].height
            let origin = CGPoint(
                x: bounds.minX + padding.width,
                y: bounds.midY - contentHeight / 2
            )
            place(subviews[0], at: origin, size: sizes[0])
            place(
                subviews[1],
                at: CGPoint(x: origin.x, y: origin.y + sizes[0].height),
                size: sizes[1]
            )
            hideUnusedSubviews(in: subviews, visibleIndices: [0, 1], outside: bounds, sizes: sizes)
        case .monthOnly:
            place(
                subviews[0],
                at: CGPoint(
                    x: bounds.midX - sizes[0].width / 2,
                    y: bounds.midY - sizes[0].height / 2
                ),
                size: sizes[0]
            )
            hideUnusedSubviews(in: subviews, visibleIndices: [0], outside: bounds, sizes: sizes)
        case .none:
            hideUnusedSubviews(in: subviews, visibleIndices: [], outside: bounds, sizes: sizes)
        }
    }
}

private extension ReadCalendarTreemapTileLabelLayout {
    var desiredPadding: CGFloat {
        isSingle ? 14 : 10
    }

    /// 依次判断完整、中等、紧凑、仅月份四种层级，连月份都放不下时返回 none。
    func labelLevel(for size: CGSize, textSizes: [CGSize]) -> ReadCalendarMonthContributionTreemap.TileLabelLevel {
        let monthSize = textSizes[0]
        let percentSize = textSizes[1]
        let durationSize = textSizes[2]
        let activeDaysSize = textSizes[3]
        let topRowSize = CGSize(
            width: monthSize.width + gap + percentSize.width,
            height: max(monthSize.height, percentSize.height)
        )

        let fullContentSize = CGSize(
            width: max(topRowSize.width, max(durationSize.width, activeDaysSize.width)),
            height: topRowSize.height + gap + durationSize.height + gap + activeDaysSize.height
        )
        if fits(fullContentSize, in: size, horizontalPadding: desiredPadding, verticalPadding: desiredPadding) {
            return .full
        }

        let mediumContentSize = CGSize(
            width: max(topRowSize.width, durationSize.width),
            height: topRowSize.height + gap + durationSize.height
        )
        if fits(mediumContentSize, in: size, horizontalPadding: 8, verticalPadding: 8) {
            return .medium
        }

        let compactContentSize = CGSize(
            width: max(monthSize.width, percentSize.width),
            height: monthSize.height + percentSize.height
        )
        if fits(compactContentSize, in: size, horizontalPadding: 8, verticalPadding: 6) {
            return .compact
        }

        if fits(monthSize, in: size, horizontalPadding: 4, verticalPadding: 4) {
            return .monthOnly
        }

        return .none
    }

    /// 同时校验宽高及实际内边距，避免测量通过后在摆放阶段再次发生裁切。
    func fits(
        _ contentSize: CGSize,
        in containerSize: CGSize,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat
    ) -> Bool {
        contentSize.width + horizontalPadding * 2 <= containerSize.width
            && contentSize.height + verticalPadding * 2 <= containerSize.height
    }

    /// 摆放月份与占比顶部行，并按两者真实行高做垂直居中。
    func placeTopRow(
        in bounds: CGRect,
        padding: CGFloat,
        sizes: [CGSize],
        subviews: Subviews
    ) {
        let rowHeight = max(sizes[0].height, sizes[1].height)
        let monthOrigin = CGPoint(
            x: bounds.minX + padding,
            y: bounds.minY + padding + (rowHeight - sizes[0].height) / 2
        )
        let percentOrigin = CGPoint(
            x: monthOrigin.x + sizes[0].width + gap,
            y: bounds.minY + padding + (rowHeight - sizes[1].height) / 2
        )
        place(subviews[0], at: monthOrigin, size: sizes[0])
        place(subviews[1], at: percentOrigin, size: sizes[1])
    }

    /// 将完整层级的时长和活跃天数贴近底部摆放，保留 Android 同源信息层级。
    func placeBottomDetails(
        in bounds: CGRect,
        padding: CGFloat,
        sizes: [CGSize],
        subviews: Subviews
    ) {
        let activeDaysOrigin = CGPoint(
            x: bounds.minX + padding,
            y: bounds.maxY - padding - sizes[3].height
        )
        let durationOrigin = CGPoint(
            x: bounds.minX + padding,
            y: activeDaysOrigin.y - gap - sizes[2].height
        )
        place(subviews[2], at: durationOrigin, size: sizes[2])
        place(subviews[3], at: activeDaysOrigin, size: sizes[3])
    }

    /// 使用子视图的固有尺寸摆放文本，禁止父级提议触发换行或压缩。
    func place(_ subview: LayoutSubview, at origin: CGPoint, size: CGSize) {
        subview.place(
            at: origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: size.width, height: size.height)
        )
    }

    /// SwiftUI Layout 不会自动隐藏未摆放的子视图，因此将降级层级之外的文本移到块边界外。
    func hideUnusedSubviews(
        in subviews: Subviews,
        visibleIndices: Set<Int>,
        outside bounds: CGRect,
        sizes: [CGSize]
    ) {
        let hiddenOrigin = CGPoint(x: bounds.maxX + 1, y: bounds.maxY + 1)
        for index in subviews.indices where !visibleIndices.contains(index) {
            place(subviews[index], at: hiddenOrigin, size: sizes[index])
        }
    }
}
