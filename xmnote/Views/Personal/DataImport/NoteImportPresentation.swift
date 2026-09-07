/**
 * [INPUT]: 依赖来源说明、平台角标、Asset Catalog 深浅色插画与项目设计系统
 * [OUTPUT]: 提供导入功能私有的插画页头、结构化步骤、帮助入口与预览提示
 * [POS]: Views/Personal/DataImport 的展示组件，由文件、剪贴板及 Kindle 输入页共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 插画表达实际输入载体；资源映射不参与文件过滤和解析器选择。
enum NoteImportIllustration: String {
    case json, txt, csv, zip, epub, html, md, file, clipboard

    var resourceName: String { "NoteImport" + rawValue.capitalized }
}

/// 每个准备动作具有稳定顺序、简短标题与可以自然换行的说明。
struct NoteImportPreparationStep {
    let title: String
    let detail: String
}

/// 聚焦输入载体和任务标题；已有输入时收紧展示，让文件或原文成为视觉主体。
struct NoteImportHero: View {
    let illustration: NoteImportIllustration
    let title: String
    let subtitle: String
    var isCompact = false
    var platform: NoteImportPlatform? = nil

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(illustration.resourceName)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: illustrationSize, height: illustrationSize)
                .overlay(alignment: .bottomLeading) {
                    if let platform {
                        NoteImportPlatformBadge(platform: platform, isCompact: isCompact)
                            .offset(x: isCompact ? 4 : 8, y: isCompact ? 2 : 4)
                    }
                }
                .accessibilityHidden(true)
            VStack(spacing: Spacing.half) {
                Text(title)
                    .font(isCompact ? AppTypography.title3Semibold : NoteImportTypography.heroTitle)
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.base)
    }

    private var illustrationSize: CGFloat { isCompact ? 65 : 116 }
}

/// 两步准备指引通过编号与主次文本区分层级，不额外包裹卡片。
struct NoteImportPreparationSteps: View {
    let steps: [NoteImportPreparationStep]
    @ScaledMetric(relativeTo: .subheadline) private var numberSize: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: Spacing.base) {
                    Text("\(index + 1)")
                        .font(AppTypography.subheadlineMedium)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: numberSize, height: numberSize)
                        .background(Color.surfaceNested, in: Circle())
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text(step.title)
                            .font(AppTypography.headline)
                            .foregroundStyle(Color.textPrimary)
                        Text(step.detail)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 次级帮助保留中性色与完整点击区，不与底部主操作争夺焦点。
struct NoteImportHelpButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.half) {
                Text(title)
                Image(systemName: "chevron.forward")
                    .accessibilityHidden(true)
            }
            .font(AppTypography.subheadline)
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.textSecondary)
    }
}

/// 在输入阶段明确下一步只是预览，最终导入仍需用户确认。
struct NoteImportPreviewHint: View {
    var body: some View {
        Text("先预览，确认后再导入")
            .font(AppTypography.footnote)
            .foregroundStyle(Color.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("准备导入 · 320pt") {
    let guide = NoteImportSourceGuide(title: "阅读", input: .file(parserID: .legado))
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.section) {
            NoteImportHero(illustration: guide.illustration, title: guide.heading, subtitle: guide.subtitle, platform: guide.platform)
            NoteImportPreparationSteps(steps: guide.preparationSteps)
            NoteImportHelpButton(title: guide.helpTitle, action: {})
        }
        .padding(Spacing.screenEdge)
    }
    .frame(width: 320)
    .background(Color.surfacePage)
}

#Preview("已有输入 · 深色大字号") {
    NoteImportHero(
        illustration: .clipboard,
        title: "从剪贴板导入",
        subtitle: "复制完整笔记，保留书籍信息",
        isCompact: true,
        platform: .weRead
    )
    .padding(Spacing.screenEdge)
    .background(Color.surfacePage)
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility3)
}
