/**
 * [INPUT]: 依赖 SwiftUI Menu/Layout、AppTypography 调用方字体、语义颜色、Spacing、XMMenuStyle 与 xmMinimumHitTarget
 * [OUTPUT]: 对外提供 XMPopupButton，以原生菜单统一当前值文本、Popup 指示器、动态字号测量和非侵入式最小命中区
 * [POS]: UIComponents/Controls/Menu 的跨功能弹出选择基础组件，被紧凑当前值菜单入口复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 展示单行当前值并通过原生菜单切换离散选项；业务加载、选择和保存状态仍由调用方持有。
struct XMPopupButton<MenuContent: View>: View {
    private let title: String
    private let font: Font
    private let truncationMode: Text.TruncationMode
    private let hitTargetAnchor: XMMinimumHitTargetAnchor
    @ViewBuilder private let content: MenuContent

    /// 创建原生弹出菜单；调用方传入语义字体，组件按实际文本高度同步缩放指示器。
    init(
        _ title: String,
        font: Font,
        truncationMode: Text.TruncationMode = .tail,
        hitTargetAnchor: XMMinimumHitTargetAnchor = .center,
        @ViewBuilder content: () -> MenuContent
    ) {
        self.title = title
        self.font = font
        self.truncationMode = truncationMode
        self.hitTargetAnchor = hitTargetAnchor
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            XMPopupButtonLabel(
                title: title,
                font: font,
                truncationMode: truncationMode
            )
            .xmMinimumHitTarget(anchor: hitTargetAnchor)
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
    }
}

/// 组合当前值与系统 Popup 指示器，并把可见图标高度绑定到文本的实际单行布局高度。
private struct XMPopupButtonLabel: View {
    let title: String
    let font: Font
    let truncationMode: Text.TruncationMode

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        XMPopupButtonLabelLayout(
            spacing: Spacing.micro,
            layoutDirection: layoutDirection
        ) {
            Text(title)
                .font(font)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(truncationMode)

            Image(systemName: "chevron.up.chevron.down")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.textHint)
                .accessibilityHidden(true)
        }
    }
}

/// 使用 Text 的实际测量高度为可缩放 SF Symbol 提案，避免固定字号与独立缩放产生视觉漂移。
private struct XMPopupButtonLabelLayout: Layout {
    let spacing: CGFloat
    let layoutDirection: LayoutDirection

    /// 返回单行文本与等高指示器的紧凑组合尺寸；有限宽度优先分配给不可省略的指示器。
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        measurements(proposal: proposal, subviews: subviews).size
    }

    /// 在同一垂直边界内放置文本与指示器，并让逻辑尾部随 RTL 自动镜像。
    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }

        let measurement = measurements(
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews
        )
        let textOriginX: CGFloat
        let indicatorOriginX: CGFloat

        if layoutDirection == .rightToLeft {
            indicatorOriginX = bounds.minX
            textOriginX = indicatorOriginX
                + measurement.indicatorSize.width
                + measurement.resolvedSpacing
        } else {
            textOriginX = bounds.minX
            indicatorOriginX = textOriginX
                + measurement.textSize.width
                + measurement.resolvedSpacing
        }

        let centerY = bounds.midY
        subviews[0].place(
            at: CGPoint(x: textOriginX + measurement.textSize.width / 2, y: centerY),
            anchor: .center,
            proposal: ProposedViewSize(
                width: measurement.textSize.width,
                height: measurement.textSize.height
            )
        )
        subviews[1].place(
            at: CGPoint(
                x: indicatorOriginX + measurement.indicatorSize.width / 2,
                y: centerY
            ),
            anchor: .center,
            proposal: ProposedViewSize(
                width: measurement.indicatorSize.width,
                height: measurement.indicatorSize.height
            )
        )
    }

    /// 先获取文本固有单行高度，再以该高度约束指示器，并用剩余宽度重新测量截断文本。
    private func measurements(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> XMPopupButtonLabelMeasurement {
        guard subviews.count == 2 else { return .zero }

        let naturalTextSize = subviews[0].sizeThatFits(.unspecified)
        let textHeight = naturalTextSize.height
        let proposedIndicatorSize = subviews[1].sizeThatFits(
            ProposedViewSize(width: nil, height: textHeight)
        )
        let measuredIndicatorWidth = proposedIndicatorSize.width
        let indicatorWidth = measuredIndicatorWidth.isFinite && measuredIndicatorWidth > 0
            ? min(measuredIndicatorWidth, textHeight)
            : textHeight
        let indicatorSize = CGSize(width: indicatorWidth, height: textHeight)
        let resolvedSpacing = textHeight > 0 ? spacing : Spacing.none
        let proposedTextWidth = proposal.width.map {
            max($0 - indicatorSize.width - resolvedSpacing, 0)
        }
        let measuredTextSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: proposedTextWidth, height: textHeight)
        )
        let textSize = CGSize(width: measuredTextSize.width, height: textHeight)

        return XMPopupButtonLabelMeasurement(
            textSize: textSize,
            indicatorSize: indicatorSize,
            resolvedSpacing: resolvedSpacing
        )
    }
}

/// 保存单次布局过程的确定性结果，供尺寸计算与放置共享同一几何合同。
private struct XMPopupButtonLabelMeasurement {
    let textSize: CGSize
    let indicatorSize: CGSize
    let resolvedSpacing: CGFloat

    static let zero = XMPopupButtonLabelMeasurement(
        textSize: .zero,
        indicatorSize: .zero,
        resolvedSpacing: Spacing.none
    )

    var size: CGSize {
        CGSize(
            width: textSize.width + resolvedSpacing + indicatorSize.width,
            height: textSize.height
        )
    }
}

#if DEBUG
/// 集中展示不同语义字体、长文本、禁用态与 Dynamic Type，供公共组件视觉验收。
private struct XMPopupButtonPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            XMPopupButton("DeepSeek V4 Flash", font: AppTypography.caption2) {
                Button("DeepSeek V4 Flash") { }
                Button("DeepSeek V4 Pro") { }
            }

            XMPopupButton("WebDAV", font: AppTypography.subheadline) {
                Button("WebDAV") { }
                Button("阿里云盘") { }
            }

            XMPopupButton("正文大小的弹出选择", font: AppTypography.body) {
                Button("选项一") { }
                Button("选项二") { }
            }

            XMPopupButton(
                "用于验证最长中文当前值在紧凑宽度下截断行为的示例",
                font: AppTypography.subheadline,
                truncationMode: .middle
            ) {
                Button("完整选项") { }
            }
            .frame(width: 180, alignment: .leading)

            XMPopupButton("不可用", font: AppTypography.subheadline) {
                Button("无可用选项") { }
            }
            .disabled(true)
        }
        .padding(Spacing.screenEdge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfacePage)
    }
}

#Preview("Popup Button · 默认") {
    XMPopupButtonPreview()
}

#Preview("Popup Button · 深色") {
    XMPopupButtonPreview()
        .preferredColorScheme(.dark)
}

#Preview("Popup Button · 辅助功能字号") {
    XMPopupButtonPreview()
        .dynamicTypeSize(.accessibility3)
}
#endif
