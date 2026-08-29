/**
 * [INPUT]: 依赖 NoteReviewViewModel 提供回顾设置、标签选项与已选书籍回显，依赖 BookPickerView 承接书籍范围选择
 * [OUTPUT]: 对外提供采用统一设置行文本层级的 NoteReviewSettingsSheet 与标签多选 Sheet，完成书摘回顾设置编辑
 * [POS]: Note 模块业务 Sheet，服务回顾 Tab 顶部设置入口，不直接访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 书摘回顾设置 Sheet，复用项目设置页分组风格并将写入动作委托给 ViewModel。
struct NoteReviewSettingsSheet: View {
    @Bindable var viewModel: NoteReviewViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeSheet: ActiveSheet?
    @State private var selectedBackgroundPhoto: PhotosPickerItem?
    @State private var isImportingFont = false

    private enum ActiveSheet: Identifiable {
        case books
        case tags

        var id: String {
            switch self {
            case .books:
                return "books"
            case .tags:
                return "tags"
            }
        }
    }

    var body: some View {
        XMSheetScaffold(
            title: "回顾设置",
            subtitle: "书摘范围与卡片样式",
            onClose: { dismiss() }
        ) {
            VStack(spacing: Spacing.comfortable) {
                scopeGroup
                displayGroup
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
            .animation(settingsReflowAnimation, value: viewModel.settings.selectedTagIDs)
            .animation(settingsReflowAnimation, value: viewModel.settings.palette)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .books:
                BookPickerView(
                    configuration: bookPickerConfiguration,
                    onComplete: handleBookPickerResult
                )
            case .tags:
                NoteReviewTagSelectionSheet(
                    options: viewModel.tagOptions,
                    selectedIDs: viewModel.settings.selectedTagIDs,
                    onComplete: handleTagSelection
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .task(id: selectedBackgroundPhoto) {
            await consumeBackgroundPhoto()
        }
        .fileImporter(
            isPresented: $isImportingFont,
            allowedContentTypes: [.font]
        ) { result in
            guard case .success(let url) = result else { return }
            Task { await viewModel.importFont(from: url) }
        }
    }

    private var scopeGroup: some View {
        XMSettingsGroup {
            VStack(spacing: Spacing.none) {
                NoteReviewSettingsNavigationRow(
                    title: "书籍范围",
                    value: viewModel.bookScopeSummary,
                    action: { activeSheet = .books }
                )

                NoteReviewSettingsNavigationRow(
                    title: "标签范围",
                    value: viewModel.tagScopeSummary,
                    action: { activeSheet = .tags }
                )

                if !viewModel.settings.selectedTagIDs.isEmpty {
                    XMSettingsValueMenuRow(
                        title: "标签规则",
                        value: viewModel.settings.tagMatchRule.title,
                        options: NoteReviewTagMatchRule.allCases,
                        selection: viewModel.settings.tagMatchRule,
                        optionTitle: { $0.title },
                        optionImage: { _ in nil },
                        onSelect: updateTagMatchRule
                    )
                    .transition(settingsRowTransition)
                }
            }
        }
    }

    private var displayGroup: some View {
        XMSettingsGroup {
            VStack(spacing: Spacing.none) {
                XMSettingsValueMenuRow(
                    title: "显示顺序",
                    value: viewModel.settings.sortRule.title,
                    options: NoteReviewSortRule.allCases,
                    selection: viewModel.settings.sortRule,
                    optionTitle: { $0.title },
                    optionImage: { $0.systemImage },
                    onSelect: updateSortRule
                )

                XMSettingsValueMenuRow(
                    title: "背景类型",
                    value: viewModel.settings.backgroundMode.title,
                    options: NoteReviewBackgroundMode.allCases,
                    selection: viewModel.settings.backgroundMode,
                    optionTitle: { $0.title },
                    optionImage: { _ in nil },
                    onSelect: updateBackgroundMode
                )

                if viewModel.settings.backgroundMode == .color {
                    NoteReviewPalettePickerRow(
                        selection: viewModel.settings.palette,
                        onSelect: updatePalette
                    )
                }

                if viewModel.settings.backgroundMode == .image {
                    NoteReviewBackgroundImageRow(
                        imageURL: viewModel.settings.backgroundImageURL,
                        isUploading: viewModel.isUploadingBackground,
                        onClear: clearBackgroundImage,
                        selectedPhoto: $selectedBackgroundPhoto
                    )

                    NoteReviewTextColorRow(
                        color: Binding(
                            get: { viewModel.settings.cardAppearance.onSurface },
                            set: { color in
                                Task { await viewModel.updateCustomTextColorHex(color.rgbHex) }
                            }
                        )
                    )
                }

                XMSettingsValueMenuRow(
                    title: "字体",
                    value: viewModel.settings.fontSelection.title,
                    options: fontOptions,
                    selection: viewModel.settings.fontSelection,
                    optionTitle: { $0.title },
                    optionImage: { _ in nil },
                    onSelect: updateFontSelection
                )

                Button {
                    isImportingFont = true
                } label: {
                    HStack {
                        Text("导入本地字体")
                            .font(AppTypography.subheadlineSemibold)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        if viewModel.isImportingFont {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "doc.badge.plus")
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isImportingFont)

                XMSettingsValueMenuRow(
                    title: "文本对齐",
                    value: viewModel.settings.textAlignment.title,
                    options: NoteReviewTextAlignment.allCases,
                    selection: viewModel.settings.textAlignment,
                    optionTitle: { $0.title },
                    optionImage: { _ in nil },
                    onSelect: updateTextAlignment
                )
            }
        }
    }

    private var bookPickerConfiguration: BookPickerConfiguration {
        BookPickerConfiguration(
            title: "选择回顾书籍",
            scope: .local,
            selectionMode: .multiple,
            allowsCreationFlow: false,
            multipleConfirmationPolicy: .allowsEmptyResult,
            multipleConfirmationTitle: "完成",
            preselectedBooks: viewModel.selectedBooks
        )
    }

    private var settingsReflowAnimation: Animation {
        reduceMotion ? .smooth(duration: 0.10) : .smooth(duration: 0.22)
    }

    private var settingsRowTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -Spacing.tiny)),
            removal: .opacity
        )
    }

    private func updateSortRule(_ sortRule: NoteReviewSortRule) {
        var next = viewModel.settings
        next.sortRule = sortRule
        Task { await viewModel.updateSettings(next) }
    }

    private func updateTagMatchRule(_ rule: NoteReviewTagMatchRule) {
        var next = viewModel.settings
        next.tagMatchRule = rule
        Task { await viewModel.updateSettings(next) }
    }

    private func updatePalette(_ palette: NoteReviewPalette) {
        var next = viewModel.settings
        next.palette = palette
        next.customBackgroundStartHex = nil
        next.customBackgroundEndHex = nil
        Task { await viewModel.updateSettings(next) }
    }

    private var fontOptions: [NoteReviewFontSelection] {
        var options: [NoteReviewFontSelection] = [.system, .sourceHanSerif]
        if case .local = viewModel.settings.fontSelection {
            options.append(viewModel.settings.fontSelection)
        }
        return options
    }

    private func updateBackgroundMode(_ mode: NoteReviewBackgroundMode) {
        Task { await viewModel.updateBackgroundMode(mode) }
    }

    private func updateFontSelection(_ selection: NoteReviewFontSelection) {
        var next = viewModel.settings
        next.fontSelection = selection
        Task { await viewModel.updateSettings(next) }
    }

    private func clearBackgroundImage() {
        Task { await viewModel.clearBackgroundImage() }
    }

    private func updateTextAlignment(_ alignment: NoteReviewTextAlignment) {
        var next = viewModel.settings
        next.textAlignment = alignment
        Task { await viewModel.updateSettings(next) }
    }

    private func handleBookPickerResult(_ result: BookPickerResult) {
        guard case .multiple(let selections) = result else { return }
        let books = selections.compactMap { selection -> BookPickerBook? in
            guard case .local(let book) = selection else { return nil }
            return book
        }
        Task { await viewModel.updateSelectedBooks(books) }
    }

    private func handleTagSelection(_ ids: [Int64]) {
        Task { await viewModel.updateSelectedTagIDs(ids) }
    }

    private func consumeBackgroundPhoto() async {
        guard let selectedBackgroundPhoto else { return }
        defer { self.selectedBackgroundPhoto = nil }

        do {
            guard let data = try await selectedBackgroundPhoto.loadTransferable(type: Data.self) else {
                viewModel.errorMessage = "读取背景图片失败"
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("note-review-background-\(UUID().uuidString).jpg")
            try data.write(to: url, options: .atomic)
            await viewModel.uploadBackgroundImage(from: url)
        } catch {
            guard !Task.isCancelled else { return }
            viewModel.errorMessage = "读取背景图片失败：\(error.localizedDescription)"
        }
    }
}

private struct NoteReviewBackgroundImageRow: View {
    let imageURL: String?
    let isUploading: Bool
    let onClear: () -> Void
    @Binding var selectedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            HStack {
                Text("背景图片")
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if isUploading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Text(imageURL == nil ? "选择图片" : "更换图片")
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.appTint)
                    }
                }
            }

            if imageURL != nil {
                Button("清除图片", action: onClear)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.feedbackWarning)
            }
        }
        .frame(minHeight: 52)
    }
}

private struct NoteReviewTextColorRow: View {
    @Binding var color: Color

    var body: some View {
        HStack {
            Text("文字颜色")
                .font(SettingsTypography.rowTitle)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
        }
        .frame(minHeight: 52)
    }
}

private struct NoteReviewPalettePickerRow: View {
    let selection: NoteReviewPalette
    let onSelect: (NoteReviewPalette) -> Void

    /// 归一化后的当前选择，避免历史持久化值影响标题与选中态。
    private var canonicalSelection: NoteReviewPalette {
        selection.canonicalPalette
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            HStack(spacing: Spacing.base) {
                Text("卡片配色")
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)

                Spacer(minLength: Spacing.base)

                Text(canonicalSelection.title)
                    .font(SettingsTypography.rowValue)
                    .foregroundStyle(Color.textHint)
                    .contentTransition(.opacity)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.cozy) {
                    ForEach(NoteReviewPalette.selectablePalettes, id: \.self) { palette in
                        Button {
                            guard palette != canonicalSelection else { return }
                            onSelect(palette)
                        } label: {
                            RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                                .fill(palette.cardSurfaceColor)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                                        .stroke(
                                            palette == canonicalSelection ? Color.selectionAccent : Color.surfaceBorderSubtle,
                                            lineWidth: palette == canonicalSelection ? 2 : StrokeWidth.hairline
                                        )
                                }
                                .overlay {
                                    if palette == canonicalSelection {
                                        Image(systemName: "checkmark")
                                            .font(AppTypography.captionSemibold)
                                            .foregroundStyle(palette.cardOnSurfaceColor)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(palette.title)
                        .accessibilityAddTraits(palette == canonicalSelection ? .isSelected : [])
                    }
                }
                .padding(.vertical, Spacing.micro)
            }
        }
        .frame(minHeight: 78)
    }
}

private enum NoteReviewSettingsNavigationRowLayout {
    static let minimumHeight: CGFloat = 52
    static let minimumValueScale = 0.82
}

/// 书摘回顾设置的子选择入口，展示动态摘要并打开页面私有选择器。
private struct NoteReviewSettingsNavigationRow: View {
    let title: LocalizedStringResource
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                Text(title)
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.base)

                Text(value)
                    .font(SettingsTypography.rowValue)
                    .foregroundStyle(Color.textHint)
                    .lineLimit(1)
                    .minimumScaleFactor(NoteReviewSettingsNavigationRowLayout.minimumValueScale)

                Image(systemName: "chevron.right")
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(Color.textHint)
            }
            .frame(minHeight: NoteReviewSettingsNavigationRowLayout.minimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(String(localized: title))，当前\(value)")
    }
}

private struct NoteReviewTagSelectionSheet: View {
    let options: [NoteReviewTagOption]
    let selectedIDs: [Int64]
    let onComplete: ([Int64]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftIDs: Set<Int64>

    init(
        options: [NoteReviewTagOption],
        selectedIDs: [Int64],
        onComplete: @escaping ([Int64]) -> Void
    ) {
        self.options = options
        self.selectedIDs = selectedIDs
        self.onComplete = onComplete
        self._draftIDs = State(initialValue: Set(selectedIDs))
    }

    var body: some View {
        XMSheetScaffold(
            title: "选择标签",
            subtitle: draftSummary,
            onClose: { dismiss() },
            bottomBar: {
                actionBar
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.vertical, Spacing.cozy)
            }
        ) {
            VStack(spacing: Spacing.comfortable) {
                if options.isEmpty {
                    XMCompactStateView(
                        role: .empty,
                        title: "暂无书摘标签"
                    )
                        .frame(minHeight: 220)
                } else {
                    tagGroup
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }

    private var tagGroup: some View {
        XMSettingsGroup {
            VStack(spacing: Spacing.none) {
                ForEach(options) { option in
                    Button {
                        toggle(option.id)
                    } label: {
                        HStack(spacing: Spacing.base) {
                            VStack(alignment: .leading, spacing: Spacing.micro) {
                                Text(option.title)
                                    .font(AppTypography.subheadlineSemibold)
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(1)

                                Text("\(option.noteCount) 条书摘")
                                    .font(AppTypography.caption2)
                                    .foregroundStyle(Color.textSecondary)
                            }

                            Spacer(minLength: Spacing.base)

                            XMSelectionIndicator(
                                style: .checkbox,
                                isSelected: draftIDs.contains(option.id),
                                font: AppTypography.title3,
                                showsUnselectedBase: true
                            )
                        }
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(option.title)
                    .accessibilityValue(draftIDs.contains(option.id) ? "已选择" : "未选择")
                    .accessibilityAddTraits(draftIDs.contains(option.id) ? .isSelected : [])
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: Spacing.base) {
            Button {
                draftIDs.removeAll()
            } label: {
                Text("清空")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: InteractionMetrics.minimumTouchTarget)
            }
            .buttonStyle(.bordered)
            .disabled(draftIDs.isEmpty)

            Button {
                onComplete(options.map(\.id).filter { draftIDs.contains($0) })
                dismiss()
            } label: {
                Text("完成")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: InteractionMetrics.minimumTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.primaryActionFill)
        }
    }

    private var draftSummary: String {
        draftIDs.isEmpty ? "不限标签" : "已选择 \(draftIDs.count) 个标签"
    }

    private func toggle(_ id: Int64) {
        if draftIDs.contains(id) {
            draftIDs.remove(id)
        } else {
            draftIDs.insert(id)
        }
    }
}
