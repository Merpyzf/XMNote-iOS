/**
 * [INPUT]: 依赖 KindleImportEntryPoint、XMSheetScaffold 与设计系统
 * [OUTPUT]: 提供 Kindle 前置方式选择，以及按入口区分的准备步骤与帮助
 * [POS]: Views/Personal/DataImport 的 Kindle 输入引导；不读取设备或文件
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 目录中的前置选择仅承载两个入口，完整教程在选择后的页面中展示。
struct KindleImportMethodSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onSelect: (KindleImportEntryPoint) -> Void

    var body: some View {
        XMSheetScaffold(title: "从 Kindle 导入", onClose: { dismiss() }) {
            VStack(spacing: Spacing.none) {
                methodRow(.connectedDevice, icon: .reiconExternalDriveOutline, detail: "通过系统“文件”选择设备中的书摘")
                Divider()
                methodRow(.manualFile, icon: .reiconFileTextOutline, detail: "导入已保存的 My Clippings.txt")
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    /// 每行是一个完整的选择目标，图标不重复朗读，长文案自然增高。
    private func methodRow(_ entryPoint: KindleImportEntryPoint, icon: ImageResource, detail: String) -> some View {
        Button { onSelect(entryPoint) } label: {
            HStack(spacing: Spacing.base) {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(Color.iconSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text(KindleImportGuide(entryPoint: entryPoint).title)
                        .font(AppTypography.headline)
                        .foregroundStyle(Color.textPrimary)
                    Text(detail)
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .foregroundStyle(Color.iconSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Spacing.section)
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 两种入口只改变获取文件前的说明，文件约束和解析链路保持一致。
struct KindleImportGuide {
    let entryPoint: KindleImportEntryPoint

    var title: String {
        entryPoint == .connectedDevice ? "连接 Kindle 导入" : "选择文件导入"
    }

    var steps: [NoteImportPreparationStep] {
        switch entryPoint {
        case .connectedDevice:
            [
                .init(title: "连接 Kindle", detail: "使用数据线或转接器连接 Kindle，确认设备已出现在系统“文件”中。"),
                .init(title: "选择书摘文件", detail: "打开设备的 Documents 文件夹，选择 My Clippings.txt。")
            ]
        case .manualFile:
            [
                .init(title: "准备书摘文件", detail: "将 Kindle 中的 My Clippings.txt 保存到 iCloud Drive 或当前设备的“文件”中。"),
                .init(title: "选择并预览", detail: "选择保存的文件，即可预览其中多本书的书摘。")
            ]
        }
    }

    var help: String {
        switch entryPoint {
        case .connectedDevice:
            "在系统“文件”的“浏览 → 位置”中查找 Kindle。若设备没有出现，请检查连接线、转接器和设备上的连接提示。仍无法找到时，可先通过电脑取得 Documents 中的 My Clippings.txt，再保存到当前设备；返回导入目录，选择“选择文件导入”。"
        case .manualFile:
            "在 Kindle 的 Documents 文件夹中找到 My Clippings.txt，通过电脑将它保存到 iCloud Drive 或发送到当前设备。请保留原文件名和内容，无需按书籍拆分。"
        }
    }
}

/// 完整准备说明按当前模式提供，保持主输入页的两步指引简洁。
struct KindleImportHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    let guide: KindleImportGuide

    var body: some View {
        XMSheetScaffold(title: "Kindle 导入帮助", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                NoteImportPreparationSteps(steps: guide.steps)
                Text(guide.help)
                    .font(AppTypography.callout)
                    .foregroundStyle(Color.textSecondary)
                Text("仅支持 My Clippings.txt，单个文件最大 32 MiB。解析完成后先预览，确认后再导入。")
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .presentationDetents([.large])
    }
}
