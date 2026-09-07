/**
 * [INPUT]: 依赖导入偏好草稿、有效来源时长与设置组件
 * [OUTPUT]: 提供有笔记、阅读时长和排序三个轻量条件
 * [POS]: Views/Personal/DataImport 的功能私有筛选，不维护命名方案
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import SwiftUI

/// 取消不改变条件，确认经 Repository 保存最近偏好。
struct NoteImportFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: NoteImportPreviewViewModel
    @State private var draft: NoteImportFilter
    /// 复制当前条件，阅读状态在主页面独立表达。
    init(model: NoteImportPreviewViewModel) {
        self.model = model; _draft = State(initialValue: model.filter)
    }
    var body: some View {
        XMSheetScaffold(title: "筛选", onClose: { dismiss() }, confirmationAction: { model.applyFilter(draft); dismiss() }) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                XMSettingsGroup {
                    Toggle("仅显示有笔记的书", isOn: $draft.onlyWithNotes)
                        .font(AppTypography.body).frame(minHeight: InteractionMetrics.minimumTouchTarget)
                }
                if model.hasDurations {
                    XMSettingsGroup {
                        VStack(alignment: .leading, spacing: Spacing.none) {
                            Text("阅读时长").font(AppTypography.body).padding(.vertical, Spacing.cozy)
                            ForEach(NoteImportDurationFilter.allCases.filter { $0 != .missing || model.hasMissingDurations }, id: \.self) { option in
                                Button { draft.duration = option } label: {
                                    HStack {
                                        Text(option.title).font(AppTypography.subheadline)
                                        Spacer()
                                        if draft.duration == option { Image(systemName: "checkmark").accessibilityHidden(true) }
                                    }.frame(minHeight: InteractionMetrics.minimumTouchTarget).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).accessibilityAddTraits(draft.duration == option ? .isSelected : [])
                            }
                        }
                    }
                }
                XMSettingsGroup {
                    XMSettingsValueMenuRow(title: "排序", value: draft.sort.title,
                        options: [NoteImportSort.source, .title, .contentCount], selection: draft.sort,
                        optionTitle: { $0.title }, optionImage: { _ in nil }, onSelect: { draft.sort = $0 })
                }
                Button("重置") {
                    let statuses = draft.statuses; draft = .init(); draft.statuses = statuses
                }.font(AppTypography.body).tint(Color.textSecondary).frame(minHeight: InteractionMetrics.minimumTouchTarget)
            }
            .padding(.horizontal, Spacing.screenEdge).padding(.bottom, Spacing.contentEdge)
        }
        .tint(Color.textPrimary)
    }
}
