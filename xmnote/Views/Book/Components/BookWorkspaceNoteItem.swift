/**
 * [INPUT]: 依赖 NoteExcerpt、ExpandableRichText、XMJXImageWall、XMTagLabel 与 DesignTokens 展示单书工作台章节、书摘和头部排版令牌
 * [OUTPUT]: 对 BookDetailView 提供统一结构轴、具备对称边界呼吸并带无缝连续书名、色点中性状态与评分缺席态等距底部呼吸的独立普通评分胶囊的无边缘光晕封面影像 Hero、低于书摘正文的统一出版元数据层级、三项轻透阅读指标 Chip、中性内容台阶与折叠导航中和布局刻度，以及共享中性画布的章节和书摘内容
 * [POS]: Views/Book/Components 的页面私有内容组件，承接影像 Hero 头部节奏、中性内容层、章节分组和具备清晰信息亲密性的书摘列表项
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 单书工作台专用布局刻度；把 Android 的紧凑节奏转换为当前 iOS 设计系统，不影响全局间距令牌。
enum BookWorkspaceLayoutMetrics {
    static let pageHorizontalInset: CGFloat = Spacing.base
    static let headerHorizontalInset: CGFloat = Spacing.screenEdge
    static let sectionHeaderHorizontalInset: CGFloat = Spacing.screenEdge
    static let cardContentInset: CGFloat = Spacing.screenEdge
    static let itemSpacing: CGFloat = Spacing.base
    static let chapterToFirstItemSpacing: CGFloat = Spacing.cozy
    static let sectionSpacing: CGFloat = Spacing.section
    static let contentBlockSpacing: CGFloat = 10
    static let metadataSpacing: CGFloat = 8
    static let minimumControlHeight: CGFloat = InteractionMetrics.minimumTouchTarget
    static let headerTopInset: CGFloat = Spacing.double
    static let headerBottomInset: CGFloat = Spacing.double
    static let identityCoverSpacing: CGFloat = Spacing.screenEdge
    static let identityPrimarySpacing: CGFloat = Spacing.compact
    static let identitySecondarySpacing: CGFloat = Spacing.compact
    static let identityToMetricsSpacing: CGFloat = Spacing.compact
    static let titleStatusSpacing: CGFloat = Spacing.cozy
    static let titleStatusRowHeight: CGFloat = minimumControlHeight
    static let readStatusBadgeVisualHeight: CGFloat = 22
    static let readStatusDotSize: CGFloat = 6
    static let readStatusContentSpacing: CGFloat = Spacing.compact
    static let readStatusHorizontalInset: CGFloat = Spacing.cozy
    static let metricChipSpacing: CGFloat = Spacing.cozy
    static let metricChipIconSpacing: CGFloat = 5
    static let metricChipHorizontalInset: CGFloat = 9
    static let metricChipVisualHeight: CGFloat = 26
    static let headerChipFillOpacity = 0.18
    static let headerChipPressedFillOpacity = 0.24
    static let headerChipLightBorderOpacity = 0.30
    static let headerChipDarkBorderOpacity = 0.14
    static let metricsEdgeFadeWidth: CGFloat = Spacing.screenEdge
    static let ratingSlotHeight: CGFloat = 48
    static let ratingCapsuleHeight: CGFloat = 26
    static let ratingCapsuleVerticalInset = max(
        (ratingSlotHeight - ratingCapsuleHeight) / 2,
        0
    )
    static let ratingCapsuleHorizontalInset: CGFloat = 7
    static let ratingStarSize: CGFloat = 12
    static let ratingStarSpacing: CGFloat = 1
    static let ratingStarCount = 5
    static let ratingCapsuleVisualWidth = CGFloat(ratingStarCount) * ratingStarSize
        + CGFloat(ratingStarCount - 1) * ratingStarSpacing
        + ratingCapsuleHorizontalInset * 2
    static let scopeItemSpacing: CGFloat = Spacing.double
    static let scopeTitleCountSpacing: CGFloat = Spacing.compact
    static let scopeIndicatorWidth: CGFloat = 24
    static let scopeIndicatorHeight: CGFloat = 3
    static let scopeIndicatorOffset: CGFloat = Spacing.tight
    static let scopeAccessibilityIndicatorSpacing: CGFloat = Spacing.cozy
    static let scopeBarEstimatedHeight: CGFloat = InteractionMetrics.minimumTouchTarget
    static let contentStepTopCornerRadius: CGFloat = 20
    static let contentStepBoundaryOpacity: CGFloat = 0.18
    static let navigationNeutralizationDistance: CGFloat = 64
}

/// 单书工作台头部排版令牌；保证公共书名跑马灯接收同源渲染字体与行高。
enum BookWorkspaceTypography {
    static let title: Font = AppTypography.semantic(.title3, weight: .medium)
    static let uiTitle: UIFont = AppTypography.uiSemantic(.title3, weight: .medium)
    static let secondaryInformation: Font = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .subheadline,
        minimumPointSize: 14
    )
    static let metricValue: Font = AppTypography.caption2Medium
    static let metricIcon: Font = AppTypography.caption2

    static var titleLineHeight: CGFloat {
        ceil(uiTitle.lineHeight + Spacing.tiny)
    }
}

/// 单书工作台内容表面的页面私有样式，只保留不抢正文的弱语义描边。
enum BookWorkspaceCardSurfaceStyle {
    static let cornerRadius = CornerRadius.blockLarge

    static var border: Color {
        Color.surfaceBorderSubtle.opacity(0.55)
    }
}

/// 单书工作台的章节标题；作为 Collection supplementary header 时保留原生粘性与推离行为。
struct BookWorkspaceChapterHeader: View {
    let title: String
    let count: Int
    let isStarred: Bool
    let canvasColor: Color
    let canvasPaletteID: UInt64
    let reduceMotion: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Text(title)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.leading)

            if isStarred {
                Image(systemName: "star.fill")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityLabel("已收藏")
            }

            Spacer(minLength: Spacing.base)
        }
        .padding(.horizontal, BookWorkspaceLayoutMetrics.sectionHeaderHorizontalInset)
        .padding(.vertical, Spacing.compact)
        .frame(minHeight: BookWorkspaceLayoutMetrics.minimumControlHeight)
        .background(canvasColor)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: canvasPaletteID
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHeading(.h2)
    }

    private var accessibilityLabel: String {
        var components = [title, "\(count) 条"]
        if isStarred {
            components.append("已收藏")
        }
        return components.joined(separator: "，")
    }
}

/// 单书工作台书摘列表项，按正文、想法、附图、标签、元信息的稳定顺序组织内容。
struct BookWorkspaceNoteItem: View {
    let note: NoteExcerpt
    let footerText: String
    let surfaceColor: Color
    @Binding var isContentExpanded: Bool
    @Binding var isIdeaExpanded: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        cardContent
            .contentShape(
                .contextMenuPreview,
                RoundedRectangle(
                    cornerRadius: BookWorkspaceCardSurfaceStyle.cornerRadius,
                    style: .continuous
                )
            )
            .contextMenu {
                Button("查看完整内容", systemImage: "doc.text.magnifyingglass", action: onOpen)
                Button("编辑书摘", systemImage: "square.and.pencil", action: onEdit)
                Button("复制书摘", systemImage: "doc.on.doc", action: copyNote)
            }
            .xmMenuNeutralTint()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BookWorkspaceLayoutMetrics.pageHorizontalInset)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "查看完整内容", onOpen)
            .accessibilityAction(named: "编辑书摘", onEdit)
            .accessibilityAction(named: "复制书摘", copyNote)
    }

    private var cardContent: some View {
        let shape = RoundedRectangle(
            cornerRadius: BookWorkspaceCardSurfaceStyle.cornerRadius,
            style: .continuous
        )
        return VStack(alignment: .leading, spacing: BookWorkspaceLayoutMetrics.metadataSpacing) {
            noteContent

            if hasMetadata {
                metadataRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BookWorkspaceLayoutMetrics.cardContentInset)
        .background(surfaceColor, in: shape)
        .overlay {
            shape.strokeBorder(
                BookWorkspaceCardSurfaceStyle.border,
                lineWidth: StrokeWidth.hairline
            )
        }
    }

    private var noteContent: some View {
        VStack(alignment: .leading, spacing: BookWorkspaceLayoutMetrics.contentBlockSpacing) {
            if note.hasSourceContent {
                ExpandableRichText(
                    html: note.content,
                    isExpanded: $isContentExpanded,
                    baseFont: ReadingContentTypography.uiBody,
                    textColor: UIColor.xmResolved(Color.textPrimary),
                    lineSpacing: ReadingContentTypography.bodyLineSpacing,
                    maxLines: 6,
                    actionColor: Color.textSecondary,
                    accessibilitySubject: "书摘正文",
                    animatesExpansionInternally: false,
                    onContentTap: onOpen
                )
            }

            if note.hasSourceIdea {
                HStack(alignment: .top, spacing: BookWorkspaceLayoutMetrics.contentBlockSpacing) {
                    RoundedRectangle(cornerRadius: CornerRadius.inlayHairline, style: .continuous)
                        .fill(Color.textHint.opacity(0.6))
                        .frame(width: Spacing.micro)

                    ExpandableRichText(
                        html: note.idea,
                        isExpanded: $isIdeaExpanded,
                        baseFont: ReadingContentTypography.uiAnnotation,
                        textColor: UIColor.xmResolved(Color.textSecondary),
                        lineSpacing: ReadingContentTypography.annotationLineSpacing,
                        maxLines: 4,
                        actionColor: Color.textSecondary,
                        accessibilitySubject: "书摘想法",
                        animatesExpansionInternally: false,
                        onContentTap: onOpen
                    )
                }
            }

            if !note.imageURLs.isEmpty {
                XMJXImageWall(
                    items: imageItems,
                    columnCount: note.imageURLs.count == 1 ? 1 : 3,
                    spacing: Spacing.half,
                    priority: .normal
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var metadataRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: BookWorkspaceLayoutMetrics.metadataSpacing) {
                if !note.tagNames.isEmpty {
                    tags
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !footerText.isEmpty {
                    footer
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: BookWorkspaceLayoutMetrics.metadataSpacing) {
                if !note.tagNames.isEmpty {
                    tags
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }

                if !footerText.isEmpty {
                    footer
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var hasMetadata: Bool {
        !note.tagNames.isEmpty || !footerText.isEmpty
    }

    private var footer: some View {
        Text(footerText)
            .font(ReadingContentTypography.metadata)
            .foregroundStyle(Color.textSecondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
    }

    private var tags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.tight) {
                ForEach(note.tagNames, id: \.self) { tag in
                    XMTagLabel(tag)
                }
            }
            .padding(.vertical, Spacing.hairline)
        }
    }

    private var imageItems: [XMJXGalleryItem] {
        note.imageURLs.enumerated().map { index, url in
            XMJXGalleryItem(
                id: "book-workspace-note-\(note.id)-image-\(index)",
                thumbnailURL: url,
                originalURL: url
            )
        }
    }

    /// 复制可读纯文本，不把 HTML 标签或页面辅助信息写入剪贴板。
    private func copyNote() {
        var parts: [String] = []
        if !note.contentPlainText.isEmpty {
            parts.append(note.contentPlainText)
        }
        if !note.ideaPlainText.isEmpty {
            parts.append(note.ideaPlainText)
        }
        UIPasteboard.general.string = parts.joined(separator: "\n\n")
    }
}

/// 将单条书摘的展开状态隔离到行级 Observable，避免一条展开使整页 500 条书摘失效。
struct BookWorkspaceStatefulNoteItem: View {
    let row: BookWorkspaceNoteRow
    @Bindable var state: BookWorkspaceNoteRowState
    let surfaceColor: Color
    let onOpen: () -> Void
    let onEdit: () -> Void

    var body: some View {
        BookWorkspaceNoteItem(
            note: row.note,
            footerText: row.footerText,
            surfaceColor: surfaceColor,
            isContentExpanded: $state.isContentExpanded,
            isIdeaExpanded: $state.isIdeaExpanded,
            onOpen: onOpen,
            onEdit: onEdit
        )
    }
}
