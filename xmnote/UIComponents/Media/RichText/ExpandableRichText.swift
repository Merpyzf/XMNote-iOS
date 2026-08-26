/**
 * [INPUT]: 依赖 RichText 完整富文本展示、CollapsedRichTextPreview 收起态轻量预览、RichTextAppearance 与 DesignTokens，可接收外部展开状态与正文点击标识
 * [OUTPUT]: 对外提供 ExpandableRichText（可展开/收起的 HTML 富文本组件）
 * [POS]: UIComponents/Media/RichText 的跨模块复用展示组件，包装完整富文本与轻量预览提供 3 行截断 + 展开/收起切换
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 富文本展开与收起的局部结构变化语义，保持两个方向使用同一时序。
private enum ExpandableRichTextMotion {
    static let expansion = Animation.smooth(duration: 0.24)
}

/// 可展开/收起的 HTML 富文本组件；调用方可保留内部状态，也可传入 Binding 管理列表级展开状态。
struct ExpandableRichText: View, Equatable {
    let html: String
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    var textColor: UIColor = .label
    var lineSpacing: CGFloat = 4
    var maxLines: Int = 3
    var actionColor: Color = .appTint
    var quoteColor: UIColor = RichTextAppearance.quoteAccent
    var accessibilitySubject: String = "内容"
    var previewTapIdentity: AnyHashable?
    var onContentTap: (() -> Void)?
    var animatesExpansionInternally = true

    private let externalIsExpanded: Binding<Bool>?
    @State private var internalIsExpanded = false

    /// 旧时间线卡片依赖 equatable() 跳过重复 HTML 渲染；外部状态变化必须参与比较，避免列表沿用旧展开态。
    static func == (lhs: ExpandableRichText, rhs: ExpandableRichText) -> Bool {
        lhs.html == rhs.html
            && lhs.baseFont == rhs.baseFont
            && lhs.textColor == rhs.textColor
            && lhs.lineSpacing == rhs.lineSpacing
            && lhs.maxLines == rhs.maxLines
            && lhs.actionColor == rhs.actionColor
            && lhs.quoteColor == rhs.quoteColor
            && lhs.accessibilitySubject == rhs.accessibilitySubject
            && lhs.previewTapIdentity == rhs.previewTapIdentity
            && lhs.animatesExpansionInternally == rhs.animatesExpansionInternally
            && lhs.externalIsExpanded?.wrappedValue == rhs.externalIsExpanded?.wrappedValue
    }

    /// 构建自管理展开状态的富文本，保持原有调用行为不变。
    init(
        html: String,
        baseFont: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 4,
        maxLines: Int = 3,
        actionColor: Color = .textSecondary,
        quoteColor: UIColor = RichTextAppearance.quoteAccent,
        accessibilitySubject: String = "内容",
        previewTapIdentity: AnyHashable? = nil,
        animatesExpansionInternally: Bool = true,
        onContentTap: (() -> Void)? = nil,
        onPreviewTap: (() -> Void)? = nil
    ) {
        self.html = html
        self.baseFont = baseFont
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.maxLines = maxLines
        self.actionColor = actionColor
        self.quoteColor = quoteColor
        self.accessibilitySubject = accessibilitySubject
        self.previewTapIdentity = previewTapIdentity
        self.animatesExpansionInternally = animatesExpansionInternally
        self.onContentTap = onContentTap ?? onPreviewTap
        externalIsExpanded = nil
    }

    /// 构建由外部状态源控制的富文本，适合懒加载列表在回收后恢复展开状态。
    init(
        html: String,
        isExpanded: Binding<Bool>,
        baseFont: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 4,
        maxLines: Int = 3,
        actionColor: Color = .textSecondary,
        quoteColor: UIColor = RichTextAppearance.quoteAccent,
        accessibilitySubject: String = "内容",
        previewTapIdentity: AnyHashable? = nil,
        animatesExpansionInternally: Bool = true,
        onContentTap: (() -> Void)? = nil,
        onPreviewTap: (() -> Void)? = nil
    ) {
        self.html = html
        self.baseFont = baseFont
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.maxLines = maxLines
        self.actionColor = actionColor
        self.quoteColor = quoteColor
        self.accessibilitySubject = accessibilitySubject
        self.previewTapIdentity = previewTapIdentity
        self.animatesExpansionInternally = animatesExpansionInternally
        self.onContentTap = onContentTap ?? onPreviewTap
        externalIsExpanded = isExpanded
    }

    var body: some View {
        ExpandableRichTextCore(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maxLines: maxLines,
            actionColor: actionColor,
            quoteColor: quoteColor,
            accessibilitySubject: accessibilitySubject,
            animatesExpansionInternally: animatesExpansionInternally,
            onContentTap: onContentTap,
            isExpanded: externalIsExpanded ?? $internalIsExpanded
        )
    }
}

private struct ExpandableRichTextCore: View {
    let html: String
    let baseFont: UIFont
    let textColor: UIColor
    let lineSpacing: CGFloat
    let maxLines: Int
    let actionColor: Color
    let quoteColor: UIColor
    let accessibilitySubject: String
    let animatesExpansionInternally: Bool
    let onContentTap: (() -> Void)?

    @Binding var isExpanded: Bool
    @State private var isCollapsedContentTruncated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Group {
                if isExpanded {
                    RichText(
                        html: html,
                        baseFont: baseFont,
                        textColor: textColor,
                        lineSpacing: lineSpacing,
                        quoteColor: quoteColor,
                        maxLines: 0,
                        onContentTap: onContentTap
                    )

                    expansionAction(title: "收起", accessibilityLabel: "收起\(accessibilitySubject)", action: collapse)
                } else {
                    CollapsedRichTextPreview(
                        html: html,
                        baseFont: baseFont,
                        textColor: textColor,
                        lineSpacing: lineSpacing,
                        maxLines: maxLines,
                        onContentTap: onContentTap,
                        onTruncationChanged: { isTruncated in
                            isCollapsedContentTruncated = isTruncated
                        }
                    )

                    if isCollapsedContentTruncated {
                        expansionAction(
                            title: "展开",
                            accessibilityLabel: "展开\(accessibilitySubject)",
                            action: expand
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .transition(.identity)
        }
    }

    /// 将展开与收起作为独立 SwiftUI 控件承载，避免和 UIKit 正文点击或链接手势竞争。
    private func expansionAction(
        title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                Text(title)
                    .font(AppTypography.caption2Medium)
                    .foregroundStyle(actionColor)
                    .frame(
                        minWidth: InteractionMetrics.minimumTouchTarget,
                        minHeight: InteractionMetrics.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private func expand() {
        guard !reduceMotion, animatesExpansionInternally else {
            isExpanded = true
            return
        }
        withAnimation(ExpandableRichTextMotion.expansion) {
            isExpanded = true
        }
    }

    private func collapse() {
        guard !reduceMotion, animatesExpansionInternally else {
            isExpanded = false
            return
        }
        withAnimation(ExpandableRichTextMotion.expansion) {
            isExpanded = false
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: Spacing.double) {
            ExpandableRichText(
                html: "短文本，不会被截断。"
            )

            ExpandableRichText(
                html: "这是一段<b>很长</b>的富文本内容，用于测试展开收起功能。第一行文字。第二行文字包含<i>斜体</i>。第三行文字有<mark>高亮</mark>标记。第四行文字超出三行限制应该被截断并显示省略号和展开按钮。第五行更多内容来确保截断生效。"
            )
        }
        .padding()
    }
}
