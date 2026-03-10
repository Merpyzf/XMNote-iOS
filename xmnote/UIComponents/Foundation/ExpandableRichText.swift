/**
 * [INPUT]: 依赖 RichText 完整富文本展示、CollapsedRichTextPreview 收起态轻量预览、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 ExpandableRichText（可展开/收起的 HTML 富文本组件）
 * [POS]: UIComponents/Foundation 的跨模块复用展示组件，包装完整富文本与轻量预览提供 3 行截断 + 展开/收起切换
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 可展开/收起的 HTML 富文本组件。
/// 收起态截断到 maxLines 行 + 省略号，底部右对齐品牌色文字按钮切换展开/收起。
/// 内容不足 maxLines 时不显示按钮。
/// 展开状态为组件内部 @State，滚出屏幕回收后重置为收起态（与 Android 行为一致）。
struct ExpandableRichText: View, Equatable {
    let html: String
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    var textColor: UIColor = .label
    var lineSpacing: CGFloat = 4
    var maxLines: Int = 3

    static func == (lhs: ExpandableRichText, rhs: ExpandableRichText) -> Bool {
        lhs.html == rhs.html &&
        lhs.baseFont == rhs.baseFont &&
        lhs.textColor == rhs.textColor &&
        lhs.lineSpacing == rhs.lineSpacing &&
        lhs.maxLines == rhs.maxLines
    }

    var body: some View {
        ExpandableRichTextCore(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maxLines: maxLines
        )
    }
}

private struct ExpandableRichTextCore: View {
    let html: String
    let baseFont: UIFont
    let textColor: UIColor
    let lineSpacing: CGFloat
    let maxLines: Int

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            if isExpanded {
                RichText(
                    html: html,
                    baseFont: baseFont,
                    textColor: textColor,
                    lineSpacing: lineSpacing,
                    maxLines: 0
                )

                HStack {
                    Spacer()
                    Button {
                        collapse()
                    } label: {
                        Text("收起")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.brand)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                CollapsedRichTextPreview(
                    html: html,
                    baseFont: baseFont,
                    textColor: textColor,
                    lineSpacing: lineSpacing,
                    maxLines: maxLines,
                    onExpand: expand
                )
            }
        }
    }

    private func expand() {
        withAnimation(.snappy) {
            isExpanded = true
        }
    }

    private func collapse() {
        withAnimation(.snappy) {
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
