#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 XMBookGroupCover、XMBookCover 与 DesignTokens，使用静态封面样例验证书籍分组封面候选样式
 * [OUTPUT]: 对外提供 BookGroupCoverTestView（书籍分组封面测试页）
 * [POS]: Debug 测试页，仅用于测试中心验证 XMBookGroupCover 书盒与规整裁片候选样式，不接入正式书籍分组页面
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct BookGroupCoverTestView: View {
    private let samples = DebugBookGroupCoverSample.samples
    private let coverOptions = DebugBookGroupCoverOption.options

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                stateMatrixSection
                rowPreviewSection
                themeComparisonSection
                checklistSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .background(Color.surfacePage)
        .navigationTitle("书籍分组封面")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var stateMatrixSection: some View {
        debugSection(
            title: "组件状态矩阵",
            subtitle: "同一 58×56 尺寸下对比书盒与规整裁片的多封面、单封面、无封面状态"
        ) {
            VStack(spacing: Spacing.base) {
                ForEach(coverOptions) { option in
                    DebugBookGroupCoverOptionStateCard(option: option, samples: samples)
                }
            }
        }
    }

    private var rowPreviewSection: some View {
        debugSection(
            title: "列表行预览",
            subtitle: "观察两套候选放入真实 Item 后，是否让位于分组名和书籍数量"
        ) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                ForEach(Array(coverOptions.enumerated()), id: \.element.id) { optionIndex, option in
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text(option.title)
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(Color.textPrimary)

                        VStack(spacing: 0) {
                            ForEach(Array(samples.enumerated()), id: \.element.id) { sampleIndex, sample in
                                DebugBookGroupCoverRow(option: option, sample: sample)

                                if sampleIndex != samples.count - 1 {
                                    Divider()
                                        .padding(.leading, 58 + Spacing.base)
                                }
                            }
                        }
                    }

                    if optionIndex != coverOptions.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private var themeComparisonSection: some View {
        debugSection(
            title: "浅深色对照",
            subtitle: "重点看书盒与规整裁片在浅深色下的占位、分隔线与内容层级"
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.base) {
                    DebugBookGroupCoverThemePanel(title: "浅色", colorScheme: .light, options: coverOptions, samples: samples)
                    DebugBookGroupCoverThemePanel(title: "深色", colorScheme: .dark, options: coverOptions, samples: samples)
                }

                VStack(spacing: Spacing.base) {
                    DebugBookGroupCoverThemePanel(title: "浅色", colorScheme: .light, options: coverOptions, samples: samples)
                    DebugBookGroupCoverThemePanel(title: "深色", colorScheme: .dark, options: coverOptions, samples: samples)
                }
            }
        }
    }

    private var checklistSection: some View {
        debugSection(
            title: "验收关注点",
            subtitle: "本页只验证候选基础组件，不修改「我的 > 书籍分组」生产入口"
        ) {
            VStack(alignment: .leading, spacing: Spacing.half) {
                DebugBookGroupCoverChecklistItem(text: "书盒与规整裁片能在同一测试页并列对比")
                DebugBookGroupCoverChecklistItem(text: "规整裁片使用书籍比例矩形，不使用正方形单元")
                DebugBookGroupCoverChecklistItem(text: "规整裁片内部横向与纵向相邻封面间距一致")
                DebugBookGroupCoverChecklistItem(text: "单封面状态仍有分组占位，不误读为普通单本书")
                DebugBookGroupCoverChecklistItem(text: "无封面状态有聚合质感，占位与分隔线不会发灰或消失")
                DebugBookGroupCoverChecklistItem(text: "列表行中 chevron 弱提示，两套封面都不抢标题层级")
            }
        }
    }

    private func debugSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text(subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
                content()
                    .padding(Spacing.contentEdge)
            }
        }
    }
}

private struct DebugBookGroupCoverOptionStateCard: View {
    let option: DebugBookGroupCoverOption
    let samples: [DebugBookGroupCoverSample]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.title)
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text(option.note)
                    .font(AppTypography.caption2)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.half) {
                ForEach(samples) { sample in
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                                .fill(Color.surfaceNested)

                            XMBookGroupCover(covers: sample.covers, style: option.style)
                                .scaleEffect(1.18)
                                .frame(width: 72, height: 68)
                        }
                        .frame(width: 76, height: 72)

                        Text(sample.title)
                            .font(AppTypography.caption2Medium)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DebugBookGroupCoverRow: View {
    let option: DebugBookGroupCoverOption
    let sample: DebugBookGroupCoverSample

    var body: some View {
        HStack(spacing: Spacing.base) {
            XMBookGroupCover(covers: sample.covers, style: option.style)
                .frame(width: 58, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(sample.groupName)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Text(sample.subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.base)

            Image(systemName: "chevron.right")
                .font(AppTypography.caption)
                .foregroundStyle(Color.iconSecondary.opacity(0.32))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct DebugBookGroupCoverThemePanel: View {
    let title: String
    let colorScheme: ColorScheme
    let options: [DebugBookGroupCoverOption]
    let samples: [DebugBookGroupCoverSample]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textPrimary)

            VStack(alignment: .leading, spacing: Spacing.base) {
                ForEach(options) { option in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(option.title)
                            .font(AppTypography.caption2Medium)
                            .foregroundStyle(Color.textSecondary)

                        HStack(spacing: Spacing.base) {
                            ForEach(samples) { sample in
                                VStack(spacing: 5) {
                                    XMBookGroupCover(covers: sample.covers, style: option.style)
                                        .frame(width: 58, height: 56)

                                    Text(sample.shortTitle)
                                        .font(AppTypography.caption2Medium)
                                        .foregroundStyle(Color.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle.opacity(0.72), lineWidth: StrokeWidth.hairline)
        }
        .environment(\.colorScheme, colorScheme)
    }
}

private struct DebugBookGroupCoverChecklistItem: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
            Image(systemName: "checkmark.circle.fill")
                .font(AppTypography.caption)
                .foregroundStyle(Color.appTint)

            Text(text)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DebugBookGroupCoverOption: Identifiable {
    let id: String
    let title: String
    let note: String
    let style: XMBookGroupCover.Style

    static let options: [DebugBookGroupCoverOption] = [
        DebugBookGroupCoverOption(
            id: "collection-case",
            title: "书盒",
            note: "主封面 + 克制书脊",
            style: .collectionCaseCompact
        ),
        DebugBookGroupCoverOption(
            id: "ordered-grid",
            title: "规整裁片",
            note: "2×2 等距书籍比例裁片",
            style: .orderedGridCompact
        )
    ]
}

private struct DebugBookGroupCoverSample: Identifiable {
    let id: String
    let title: String
    let shortTitle: String
    let groupName: String
    let subtitle: String
    let covers: [String]

    static let samples: [DebugBookGroupCoverSample] = [
        DebugBookGroupCoverSample(
            id: "multi",
            title: "多封面",
            shortTitle: "多",
            groupName: "产品与设计",
            subtitle: "12 本书",
            covers: [
                "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg",
                "https://www.gutenberg.org/cache/epub/84/pg84.cover.medium.jpg",
                "https://www.gutenberg.org/cache/epub/2701/pg2701.cover.medium.jpg",
                "https://www.gutenberg.org/cache/epub/1661/pg1661.cover.medium.jpg"
            ]
        ),
        DebugBookGroupCoverSample(
            id: "single",
            title: "单封面",
            shortTitle: "单",
            groupName: "最近整理",
            subtitle: "1 本书",
            covers: [
                "https://www.gutenberg.org/cache/epub/11/pg11.cover.medium.jpg"
            ]
        ),
        DebugBookGroupCoverSample(
            id: "empty",
            title: "无封面",
            shortTitle: "空",
            groupName: "待读书单",
            subtitle: "0 本书",
            covers: []
        )
    ]
}

#Preview {
    NavigationStack {
        BookGroupCoverTestView()
    }
}
#endif
