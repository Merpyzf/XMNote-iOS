/**
 * [INPUT]: 依赖 XMRemoteImage 与 DesignTokens，依赖封面条目、容器尺寸、阶段状态与稳定随机种子
 * [OUTPUT]: 对外提供 ReadCalendarCoverFullscreenDeckStage（封面全屏容器：堆叠态 + 纵向网格态）
 * [POS]: ReadCalendar 页面私有子视图，用于浮层内“情绪化堆叠”向“可浏览列表”过渡的统一渲染
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// ReadCalendarCoverFullscreenDeckStage 负责在浮层中渲染封面堆叠态与纵向网格态。
struct ReadCalendarCoverFullscreenDeckStage: View {
    /// Phase 描述全屏容器当前展示阶段。
    enum Phase: Hashable {
        case stacked
        case grid
    }

    private struct DeckTransform {
        let offset: CGSize
        let rotation: Double
        let scale: CGFloat
        let zIndex: Double
    }

    private enum Layout {
        static let hiddenStackAnchorOpacity: CGFloat = 0.001
        static let cardAnimationDelayStep: Double = 0.024
        static let cardAnimationDelayCap: Double = 0.2
        static let cardAnimationResponse: CGFloat = 0.42
        static let cardAnimationDamping: CGFloat = 0.86
        static let borderOpacity: CGFloat = 0.45
        static let borderWidth: CGFloat = 0.45
        static let placeholderOpacity: CGFloat = 0.52
        static let goldenAngle = 2.399963229728653
        static let stackedXRadiusUnit: CGFloat = 0.62
        static let stackedYRadiusUnit: CGFloat = 0.52
        static let gridSpacing: CGFloat = 10
        static let minGridColumns = 2
        static let maxGridColumns = 4
        static let minGridScale: CGFloat = 0.84
        static let maxGridScale: CGFloat = 1.06
        static let minGridCardWidth: CGFloat = 44
    }

    let items: [ReadCalendarCoverFanStack.Item]
    let style: ReadCalendarCoverFanStack.Style
    let coverSize: CGSize
    let containerSize: CGSize
    let phase: Phase
    let phaseToken: Int
    let isAnimated: Bool
    let layoutSeed: ReadCalendarCoverFanStack.LayoutSeed
    let previewLimit: Int

    /// 创建全屏容器阶段视图，统一承载堆叠预览与纵向网格列表。
    init(
        items: [ReadCalendarCoverFanStack.Item],
        style: ReadCalendarCoverFanStack.Style,
        coverSize: CGSize,
        containerSize: CGSize,
        phase: Phase,
        phaseToken: Int,
        isAnimated: Bool,
        layoutSeed: ReadCalendarCoverFanStack.LayoutSeed,
        previewLimit: Int
    ) {
        self.items = items
        self.style = style
        self.coverSize = coverSize
        self.containerSize = containerSize
        self.phase = phase
        self.phaseToken = phaseToken
        self.isAnimated = isAnimated
        self.layoutSeed = layoutSeed
        self.previewLimit = max(1, previewLimit)
    }

    var body: some View {
        ZStack {
            stackedLayer
                .opacity(phase == .stacked ? 1 : Layout.hiddenStackAnchorOpacity)
                .allowsHitTesting(phase == .stacked)

            if phase == .grid {
                gridLayer
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .center)
        .clipped()
    }
}

private extension ReadCalendarCoverFullscreenDeckStage {
    var previewItems: [ReadCalendarCoverFanStack.Item] {
        Array(items.prefix(previewLimit))
    }

    var stackedLayer: some View {
        ZStack {
            ForEach(Array(previewItems.enumerated()), id: \.element.id) { index, item in
                let transform = stackedTransform(for: index, total: previewItems.count)
                coverCard(for: item)
                    .frame(width: coverSize.width, height: coverSize.height)
                    .rotationEffect(.degrees(transform.rotation))
                    .offset(x: transform.offset.width, y: transform.offset.height)
                    .scaleEffect(transform.scale)
                    .zIndex(transform.zIndex)
                    .shadow(
                        color: Color.black.opacity(style.shadowOpacity),
                        radius: style.shadowRadius,
                        x: style.shadowX,
                        y: style.shadowY
                    )
                    .animation(cardAnimation(for: index), value: phaseToken)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .center)
    }

    var gridLayer: some View {
        let cardSize = gridCardSize
        let columns = gridColumns(for: cardSize.width)

        return ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: columns, spacing: Layout.gridSpacing) {
                ForEach(items) { item in
                    coverCard(for: item)
                        .frame(width: cardSize.width, height: cardSize.height)
                        .shadow(
                            color: Color.black.opacity(style.shadowOpacity * 0.92),
                            radius: style.shadowRadius,
                            x: style.shadowX,
                            y: style.shadowY
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.base)
        }
    }

    /// 根据深度与总量计算堆叠态变换，保留首层聚焦并控制外扩半径。
    private func stackedTransform(for depth: Int, total: Int) -> DeckTransform {
        if depth == 0 {
            return DeckTransform(
                offset: .zero,
                rotation: Double(jitter(depth: 0, channel: 61)) * min(style.fullscreenMaxRotation, 5),
                scale: 1.14,
                zIndex: 500
            )
        }

        let spiralIndex = max(1, depth)
        let radialUnit = CGFloat(sqrt(Double(spiralIndex)))
        let angle = Layout.goldenAngle * Double(spiralIndex)
            + Double(jitter(depth: spiralIndex, channel: 67)) * 0.42

        let offsetX = cos(angle) * Double(radialUnit * coverSize.width * Layout.stackedXRadiusUnit)
        let offsetY = sin(angle) * Double(radialUnit * coverSize.height * Layout.stackedYRadiusUnit)

        return DeckTransform(
            offset: CGSize(width: offsetX, height: offsetY),
            rotation: Double(jitter(depth: spiralIndex, channel: 73)) * style.fullscreenMaxRotation,
            scale: stackedScale(for: depth, total: total),
            zIndex: stackedZIndex(for: depth, total: total)
        )
    }

    /// 计算纵向网格中的封面尺寸，优先维持封面质感并限制过度放大。
    var gridCardSize: CGSize {
        let columns = resolvedGridColumnCount
        let spacingTotal = Layout.gridSpacing * CGFloat(max(0, columns - 1))
        let availableWidth = max(0, containerSize.width - spacingTotal)
        let naturalWidth = availableWidth / CGFloat(max(1, columns))
        let minimum = max(Layout.minGridCardWidth, coverSize.width * Layout.minGridScale)
        let maximum = max(minimum, coverSize.width * Layout.maxGridScale)
        let width = min(maximum, max(minimum, naturalWidth))
        let ratio = max(1.2, coverSize.height / max(1, coverSize.width))
        return CGSize(width: width, height: width * ratio)
    }

    /// 根据容器宽度与目标卡片宽度生成纵向网格列配置。
    func gridColumns(for cardWidth: CGFloat) -> [GridItem] {
        let count = resolvedGridColumnCount
        let item = GridItem(.fixed(cardWidth), spacing: Layout.gridSpacing, alignment: .top)
        return Array(repeating: item, count: count)
    }

    /// 计算可用列数：单本使用 1 列，其他场景保持 2~4 列自适应。
    var resolvedGridColumnCount: Int {
        guard items.count > 1 else { return 1 }
        let preferredWidth = max(Layout.minGridCardWidth, coverSize.width * Layout.minGridScale)
        let rough = Int((containerSize.width + Layout.gridSpacing) / (preferredWidth + Layout.gridSpacing))
        return min(Layout.maxGridColumns, max(Layout.minGridColumns, rough))
    }

    /// 生成单张卡片的过渡动画，阶段切换时形成轻微错峰感。
    func cardAnimation(for index: Int) -> Animation? {
        guard isAnimated else { return nil }
        return .spring(
            response: Layout.cardAnimationResponse,
            dampingFraction: Layout.cardAnimationDamping
        )
        .delay(min(Layout.cardAnimationDelayCap, Double(index) * Layout.cardAnimationDelayStep))
    }

    /// 计算堆叠态缩放，首层优先强调，后续层按比例收敛。
    func stackedScale(for depth: Int, total: Int) -> CGFloat {
        if depth == 0 { return 1.14 }
        if depth == 1 { return 1.08 }
        if depth == 2 { return 1.03 }
        let ratio = CGFloat(depth) / CGFloat(max(1, total))
        return max(0.74, 0.98 - ratio * 0.24)
    }

    /// 计算堆叠态层级顺序，确保前几本封面始终位于视觉前景。
    func stackedZIndex(for depth: Int, total: Int) -> Double {
        if depth < 3 {
            return Double(480 - depth)
        }
        return Double(max(1, total - depth))
    }

    /// 生成稳定抖动值（-1...1），保证同日同数据布局可复现。
    func jitter(depth: Int, channel: UInt64) -> CGFloat {
        let depthValue = UInt64(max(0, depth) + 1)
        var state = layoutSeed.rawValue
            &+ depthValue &* 0x9E37_79B9_7F4A_7C15
            ^ channel &* 0xBF58_476D_1CE4_E5B9
        state = splitMix64(state)
        let unit = Double(state) / Double(UInt64.max)
        return CGFloat(unit * 2 - 1)
    }

    /// 执行 splitMix64 变换，提升抖动序列分布均匀性。
    func splitMix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 为全屏阶段渲染单张封面卡片；无封面地址时降级为占位样式。
    @ViewBuilder
    func coverCard(for item: ReadCalendarCoverFanStack.Item) -> some View {
        if let coverURL = normalizedCoverURL(item.coverURL) {
            XMRemoteImage(urlString: coverURL, contentMode: .fill, priority: .low) {
                coverPlaceholder
            }
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .stroke(Color.white.opacity(Layout.borderOpacity), lineWidth: Layout.borderWidth)
            }
        } else {
            coverPlaceholder
        }
    }

    /// 统一占位卡片视觉，保障无封面数据时层次感不丢失。
    var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
            .fill(Color.readCalendarSelectionFill.opacity(Layout.placeholderOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .stroke(Color.white.opacity(Layout.borderOpacity), lineWidth: Layout.borderWidth)
            }
    }

    /// 归一化封面 URL，过滤空白值避免触发无效网络请求。
    func normalizedCoverURL(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
