/**
 * [INPUT]: 依赖 BookshelfBatchEditOptions 中的标签、来源、阅读状态候选项与 BookshelfMoveGroupOption 分组封面数据，依赖外层 ViewModel 闭包提交批量写入意图
 * [OUTPUT]: 对外提供移组、标签、来源与阅读状态等批量编辑 Sheet，并统一标签/移组选择的轻量列表样式、分组封面预览与面板内读取反馈
 * [POS]: Book 模块业务 Sheet，被 BookshelfBookListView 的编辑态批量操作入口唤起
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 二级列表移入分组 Sheet，单选目标分组后提交批量移动意图。
struct BookshelfMoveGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadingGate = LoadingGate()
    @State private var optionsState: [BookshelfMoveGroupOption]
    @State private var selectedID: Int64?
    @State private var searchKeyword = ""
    @State private var createError: String?
    @State private var isCreating = false

    let options: [BookshelfMoveGroupOption]
    let selectedCount: Int
    let isLoading: Bool
    let errorMessage: String?
    let onCreate: (String) async throws -> BookEditorNamedOption
    let onConfirm: (Int64) -> Void

    /// 构建移入分组 Sheet，默认选中首个分组，并支持面板内读取与新增分组。
    init(
        options: [BookshelfMoveGroupOption],
        selectedCount: Int,
        isLoading: Bool,
        errorMessage: String?,
        onCreate: @escaping (String) async throws -> BookEditorNamedOption,
        onConfirm: @escaping (Int64) -> Void
    ) {
        self.options = options
        self.selectedCount = selectedCount
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onCreate = onCreate
        self.onConfirm = onConfirm
        self._optionsState = State(initialValue: options)
        self._selectedID = State(initialValue: options.first?.id)
    }

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: "移入分组",
            subtitle: "已选\(selectedCount)本",
            onClose: { dismiss() },
            leadingAction: {
                BookshelfBatchTopTextActionButton(
                    title: "取消",
                    foregroundColor: .textSecondary,
                    action: { dismiss() }
                )
            },
            trailingAction: {
                BookshelfBatchTopTextActionButton(
                    title: "保存",
                    foregroundColor: .brand.opacity(0.82),
                    isDisabled: !canSubmit || isCreating || isLoading || hasLoadError,
                    action: submitSelection
                )
            }
        ) {
            VStack(spacing: Spacing.base) {
                BookshelfBatchSearchField(
                    text: $searchKeyword,
                    placeholder: "搜索分组",
                    backgroundColor: .surfaceCard,
                    minHeight: 50
                )

                BookshelfBatchNamedOptionListPanel(
                    options: filteredOptions,
                    selectedIDs: selectedID.map { Set([$0]) } ?? [],
                    createTitle: canCreateSearchedGroup ? trimmedSearchKeyword : nil,
                    optionName: "分组",
                    isLoading: isLoading,
                    isLoadingVisible: loadingGate.isVisible,
                    loadErrorMessage: errorMessage,
                    isCreating: isCreating,
                    createError: createError,
                    emptyText: groupEmptyText,
                    onCreate: createGroup,
                    onToggle: selectGroup
                ) { option, isSelected, showsDivider in
                    BookshelfBatchMoveGroupOptionRow(
                        option: option,
                        isSelected: isSelected,
                        showsDivider: showsDivider
                    )
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
            .animation(sheetAnimation, value: optionsState)
            .animation(sheetAnimation, value: selectedID)
            .animation(sheetAnimation, value: canCreateSearchedGroup)
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            syncLoadingGate()
        }
        .onChange(of: searchKeyword) { _, _ in
            if !isCreating {
                createError = nil
            }
        }
        .onChange(of: options) { _, newOptions in
            syncOptions(newOptions)
        }
        .onChange(of: isLoading) { _, _ in
            syncLoadingGate()
        }
        .onDisappear {
            loadingGate.hideImmediately()
        }
    }

    private var filteredOptions: [BookshelfMoveGroupOption] {
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return optionsState }
        return optionsState.filter { option in
            option.title.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var trimmedSearchKeyword: String {
        searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreateSearchedGroup: Bool {
        guard !isLoading, !hasLoadError else { return false }
        guard !trimmedSearchKeyword.isEmpty else { return false }
        return !optionsState.contains { option in
            option.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(trimmedSearchKeyword) == .orderedSame
        }
    }

    private var groupEmptyText: String {
        trimmedSearchKeyword.isEmpty ? "暂无可移入分组" : "没有匹配的分组"
    }

    private var canSubmit: Bool {
        selectedID != nil
    }

    private var hasLoadError: Bool {
        guard let errorMessage else { return false }
        return !errorMessage.isEmpty
    }

    private var sheetAnimation: Animation {
        reduceMotion ? .smooth(duration: 0.10) : .smooth(duration: 0.22)
    }

    private func submitSelection() {
        guard let selectedID, !isCreating, !isLoading, !hasLoadError else { return }
        onConfirm(selectedID)
        dismiss()
    }

    private func selectGroup(_ id: Int64) {
        guard !isLoading, !isCreating else { return }
        selectedID = id
    }

    private func createGroup() {
        let draft = trimmedSearchKeyword
        guard !isLoading, !isCreating, canCreateSearchedGroup else { return }
        isCreating = true
        createError = nil
        Task {
            do {
                let newOption = try await onCreate(draft)
                await MainActor.run {
                    let moveGroupOption = BookshelfMoveGroupOption(
                        id: newOption.id,
                        title: newOption.title,
                        bookCount: 0,
                        representativeCovers: []
                    )
                    optionsState.removeAll { $0.id == moveGroupOption.id }
                    optionsState.insert(moveGroupOption, at: 0)
                    selectedID = moveGroupOption.id
                    searchKeyword = ""
                    createError = nil
                    isCreating = false
                }
            } catch {
                await MainActor.run {
                    createError = error.localizedDescription
                    isCreating = false
                }
            }
        }
    }

    private func syncOptions(_ options: [BookshelfMoveGroupOption]) {
        let validIDs = Set(options.map(\.id))
        optionsState = options
        if let selectedID, validIDs.contains(selectedID) {
            self.selectedID = selectedID
        } else {
            selectedID = options.first?.id
        }
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: isLoading ? .read : .none)
    }
}

/// 二级列表批量标签 Sheet，支持空选择并由 Repository 区分单本替换与多本追加。
struct BookshelfBatchTagsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadingGate = LoadingGate()
    @State private var optionsState: [BookEditorNamedOption]
    @State private var selectedIDs: Set<Int64>
    @State private var searchKeyword = ""
    @State private var createError: String?
    @State private var isCreating = false

    let options: [BookEditorNamedOption]
    let initialSelectedIDs: [Int64]
    let selectedCount: Int
    let allowsEmptySelection: Bool
    let isLoading: Bool
    let errorMessage: String?
    let onCreate: (String) async throws -> BookEditorNamedOption
    let onConfirm: ([Int64]) -> Void

    /// 构建批量标签 Sheet；支持面板内新增标签，提交语义由 Repository 区分单本替换与多本追加。
    init(
        options: [BookEditorNamedOption],
        selectedCount: Int,
        initialSelectedIDs: [Int64],
        allowsEmptySelection: Bool,
        isLoading: Bool,
        errorMessage: String?,
        onCreate: @escaping (String) async throws -> BookEditorNamedOption,
        onConfirm: @escaping ([Int64]) -> Void
    ) {
        self.options = options
        self.initialSelectedIDs = initialSelectedIDs
        self.selectedCount = selectedCount
        self.allowsEmptySelection = allowsEmptySelection
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onCreate = onCreate
        self.onConfirm = onConfirm
        let validIDs = Set(options.map(\.id))
        self._optionsState = State(initialValue: options)
        self._selectedIDs = State(initialValue: Set(initialSelectedIDs.filter { validIDs.contains($0) }))
    }

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: "设置标签",
            subtitle: "已选\(selectedCount)本",
            onClose: { dismiss() },
            leadingAction: {
                BookshelfBatchTopTextActionButton(
                    title: "取消",
                    foregroundColor: .textSecondary,
                    action: { dismiss() }
                )
            },
            trailingAction: {
                BookshelfBatchTopTextActionButton(
                    title: "保存",
                    foregroundColor: .brand.opacity(0.82),
                    isDisabled: !canSubmit || isCreating || isLoading || hasLoadError,
                    action: submitTags
                )
            }
        ) {
            VStack(spacing: Spacing.base) {
                BookshelfBatchSearchField(
                    text: $searchKeyword,
                    placeholder: "搜索标签",
                    backgroundColor: .surfaceCard,
                    minHeight: 50
                )

                BookshelfBatchNamedOptionListPanel(
                    options: filteredOptions,
                    selectedIDs: selectedIDs,
                    createTitle: canCreateSearchedTag ? trimmedSearchKeyword : nil,
                    optionName: "标签",
                    isLoading: isLoading,
                    isLoadingVisible: loadingGate.isVisible,
                    loadErrorMessage: errorMessage,
                    isCreating: isCreating,
                    createError: createError,
                    emptyText: tagEmptyText,
                    onCreate: createTag,
                    onToggle: toggle
                ) { option, isSelected, showsDivider in
                    BookshelfBatchNamedOptionRow(
                        title: option.title,
                        isSelected: isSelected,
                        showsDivider: showsDivider
                    )
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
            .animation(sheetAnimation, value: optionsState)
            .animation(sheetAnimation, value: selectedIDs)
            .animation(sheetAnimation, value: canCreateSearchedTag)
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            syncLoadingGate()
        }
        .onChange(of: searchKeyword) { _, _ in
            if !isCreating {
                createError = nil
            }
        }
        .onChange(of: options.map(\.id)) { _, _ in
            syncOptions(options, initialSelectedIDs: initialSelectedIDs)
        }
        .onChange(of: initialSelectedIDs) { _, newInitialSelectedIDs in
            syncOptions(options, initialSelectedIDs: newInitialSelectedIDs)
        }
        .onChange(of: isLoading) { _, _ in
            syncLoadingGate()
        }
        .onDisappear {
            loadingGate.hideImmediately()
        }
    }

    private var orderedSelectedIDs: [Int64] {
        optionsState.map(\.id).filter { selectedIDs.contains($0) }
    }

    private var filteredOptions: [BookEditorNamedOption] {
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return optionsState }
        return optionsState.filter { option in
            option.title.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var trimmedSearchKeyword: String {
        searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreateSearchedTag: Bool {
        guard !isLoading, !hasLoadError else { return false }
        guard !trimmedSearchKeyword.isEmpty else { return false }
        return !optionsState.contains { option in
            option.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(trimmedSearchKeyword) == .orderedSame
        }
    }

    private var tagEmptyText: String {
        trimmedSearchKeyword.isEmpty ? "暂无可用标签" : "没有匹配的标签"
    }

    private var canSubmit: Bool {
        allowsEmptySelection || !orderedSelectedIDs.isEmpty
    }

    private var hasLoadError: Bool {
        guard let errorMessage else { return false }
        return !errorMessage.isEmpty
    }

    private var sheetAnimation: Animation {
        reduceMotion ? .smooth(duration: 0.10) : .smooth(duration: 0.22)
    }

    private func submitTags() {
        guard canSubmit, !isCreating, !isLoading, !hasLoadError else { return }
        onConfirm(orderedSelectedIDs)
        dismiss()
    }

    /// 切换单个标签选中状态。
    private func toggle(_ id: Int64) {
        guard !isLoading, !isCreating else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func createTag() {
        let draft = trimmedSearchKeyword
        guard !isLoading, !isCreating, canCreateSearchedTag else { return }
        isCreating = true
        createError = nil
        Task {
            do {
                let newOption = try await onCreate(draft)
                await MainActor.run {
                    optionsState.removeAll { $0.id == newOption.id }
                    optionsState.insert(newOption, at: 0)
                    selectedIDs.insert(newOption.id)
                    searchKeyword = ""
                    createError = nil
                    isCreating = false
                }
            } catch {
                await MainActor.run {
                    createError = error.localizedDescription
                    isCreating = false
                }
            }
        }
    }

    /// 同步外部加载完成后的候选项快照，保留只属于当前有效选项集合的初始选中态。
    private func syncOptions(_ options: [BookEditorNamedOption], initialSelectedIDs: [Int64]) {
        let validIDs = Set(options.map(\.id))
        optionsState = options
        selectedIDs = Set(initialSelectedIDs.filter { validIDs.contains($0) })
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: isLoading ? .read : .none)
    }
}

/// 二级列表批量来源 Sheet，单选一个有效来源后提交。
struct BookshelfBatchSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var optionsState: [BookshelfSourceOption]
    @State private var selectedID: Int64?
    @State private var searchKeyword = ""
    @State private var createName = ""
    @State private var createError: String?
    @State private var isCreating = false

    let selectedCount: Int
    let onCreate: (String) async throws -> BookshelfSourceOption
    let onConfirm: (Int64) -> Void

    /// 构建批量来源 Sheet，支持“我的来源/默认来源”双分区与面板内新增来源。
    init(
        options: [BookshelfSourceOption],
        selectedCount: Int,
        initialSelectedID: Int64?,
        onCreate: @escaping (String) async throws -> BookshelfSourceOption,
        onConfirm: @escaping (Int64) -> Void
    ) {
        self.selectedCount = selectedCount
        self.onCreate = onCreate
        self.onConfirm = onConfirm
        let optionIDs = Set(options.map(\.id))
        let resolvedID = initialSelectedID.flatMap { optionIDs.contains($0) ? $0 : nil }
        self._optionsState = State(initialValue: options)
        self._selectedID = State(initialValue: resolvedID)
    }

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: "设置来源",
            subtitle: "已选\(selectedCount)本",
            onClose: { dismiss() }
        ) {
            VStack(spacing: Spacing.comfortable) {
                BookshelfSettingsGroupCard {
                    BookshelfBatchSearchField(
                        text: $searchKeyword,
                        placeholder: "搜索来源"
                    )
                }

                BookshelfSettingsGroupCard {
                    BookshelfBatchCreateField(
                        text: $createName,
                        placeholder: "输入新来源",
                        actionTitle: "添加",
                        isProcessing: isCreating,
                        errorMessage: createError,
                        onSubmit: createSource
                    )
                }

                if !mineOptions.isEmpty {
                    BookshelfSettingsGroupCard {
                        VStack(spacing: Spacing.none) {
                            BookshelfBatchSectionTitle(title: BookshelfSourceCategory.mine.title)
                            ForEach(mineOptions) { option in
                                Button {
                                    selectedID = option.id
                                } label: {
                                    BookshelfBatchOptionRow(
                                        title: option.title,
                                        isSelected: selectedID == option.id
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !defaultOptions.isEmpty {
                    BookshelfSettingsGroupCard {
                        VStack(spacing: Spacing.none) {
                            BookshelfBatchSectionTitle(title: BookshelfSourceCategory.appDefault.title)
                            ForEach(defaultOptions) { option in
                                Button {
                                    selectedID = option.id
                                } label: {
                                    BookshelfBatchOptionRow(
                                        title: option.title,
                                        isSelected: selectedID == option.id
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if mineOptions.isEmpty && defaultOptions.isEmpty {
                    BookshelfSettingsGroupCard {
                        BookshelfBatchEmptyHint(text: "没有匹配的来源")
                    }
                }

                Text("将 \(selectedCount) 本书的来源更新为所选来源。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    submitSelection()
                } label: {
                    Text("完成")
                        .font(AppTypography.bodyMedium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brand)
                .disabled(selectedID == nil || isCreating)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
            .animation(sheetAnimation, value: optionsState)
            .animation(sheetAnimation, value: selectedID)
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var filteredOptions: [BookshelfSourceOption] {
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return optionsState }
        return optionsState.filter { option in
            option.title.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var mineOptions: [BookshelfSourceOption] {
        filteredOptions.filter { $0.category == .mine }
    }

    private var defaultOptions: [BookshelfSourceOption] {
        filteredOptions.filter { $0.category == .appDefault }
    }

    private var sheetAnimation: Animation {
        reduceMotion ? .smooth(duration: 0.10) : .smooth(duration: 0.22)
    }

    private func submitSelection() {
        guard let selectedID else { return }
        onConfirm(selectedID)
        dismiss()
    }

    private func createSource() {
        guard !isCreating else { return }
        let draft = createName
        isCreating = true
        createError = nil
        Task {
            do {
                let newOption = try await onCreate(draft)
                await MainActor.run {
                    optionsState.removeAll { $0.id == newOption.id }
                    optionsState.append(newOption)
                    selectedID = newOption.id
                    searchKeyword = ""
                    createName = ""
                    createError = nil
                    isCreating = false
                }
            } catch {
                await MainActor.run {
                    createError = error.localizedDescription
                    isCreating = false
                }
            }
        }
    }
}

/// 批量编辑面板搜索输入，统一行高与图标语义。
private struct BookshelfBatchSearchField: View {
    @Binding var text: String
    let placeholder: String
    let backgroundColor: Color
    let minHeight: CGFloat

    /// 构建搜索输入；外层可按是否嵌入卡片调整底色与高度。
    init(
        text: Binding<String>,
        placeholder: String,
        backgroundColor: Color = .surfaceNested,
        minHeight: CGFloat = 46
    ) {
        self._text = text
        self.placeholder = placeholder
        self.backgroundColor = backgroundColor
        self.minHeight = minHeight
    }

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "magnifyingglass")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textSecondary)

            TextField(placeholder, text: $text)
                .font(AppTypography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
        .padding(.horizontal, Spacing.base)
        .frame(minHeight: minHeight)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
    }
}

/// 批量标签顶栏文字按钮的私有尺寸，维持横向胶囊比例且不影响公共设计令牌。
private enum BookshelfBatchTopTextActionButtonLayout {
    static let minWidth: CGFloat = 76
}

/// 批量编辑 Sheet 顶部的轻量文字操作按钮，承接取消与保存等编辑型动作。
private struct BookshelfBatchTopTextActionButton: View {
    let title: String
    let foregroundColor: Color
    let isDisabled: Bool
    let action: () -> Void

    /// 构建顶部文字操作按钮；禁用态保留热区但弱化文字层级。
    init(
        title: String,
        foregroundColor: Color,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.foregroundColor = foregroundColor
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.bodyMedium)
                .foregroundStyle(isDisabled ? Color.textHint : foregroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .padding(.horizontal, Spacing.base)
                .frame(
                    minWidth: BookshelfBatchTopTextActionButtonLayout.minWidth,
                    minHeight: Spacing.actionReserved
                )
                .background(Color.surfaceCard, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }
}

/// 批量编辑的命名选项轻量列表面板，统一标签与移组的搜索、创建、读取与选择节奏。
private struct BookshelfBatchNamedOptionListPanel<Option: Identifiable, RowContent: View>: View where Option.ID == Int64 {
    let options: [Option]
    let selectedIDs: Set<Int64>
    let createTitle: String?
    let optionName: String
    let isLoading: Bool
    let isLoadingVisible: Bool
    let loadErrorMessage: String?
    let isCreating: Bool
    let createError: String?
    let emptyText: String
    let onCreate: () -> Void
    let onToggle: (Int64) -> Void
    let rowContent: (Option, Bool, Bool) -> RowContent

    /// 构建批量编辑选项面板，并由调用方决定具体行内容。
    init(
        options: [Option],
        selectedIDs: Set<Int64>,
        createTitle: String?,
        optionName: String,
        isLoading: Bool,
        isLoadingVisible: Bool,
        loadErrorMessage: String?,
        isCreating: Bool,
        createError: String?,
        emptyText: String,
        onCreate: @escaping () -> Void,
        onToggle: @escaping (Int64) -> Void,
        @ViewBuilder rowContent: @escaping (Option, Bool, Bool) -> RowContent
    ) {
        self.options = options
        self.selectedIDs = selectedIDs
        self.createTitle = createTitle
        self.optionName = optionName
        self.isLoading = isLoading
        self.isLoadingVisible = isLoadingVisible
        self.loadErrorMessage = loadErrorMessage
        self.isCreating = isCreating
        self.createError = createError
        self.emptyText = emptyText
        self.onCreate = onCreate
        self.onToggle = onToggle
        self.rowContent = rowContent
    }

    var body: some View {
        VStack(spacing: Spacing.none) {
            if let loadErrorMessage, !loadErrorMessage.isEmpty {
                BookshelfBatchNamedOptionLoadErrorRow(text: loadErrorMessage)
            } else if isLoading {
                if isLoadingVisible {
                    BookshelfBatchNamedOptionLoadingRow(optionName: optionName)
                } else {
                    BookshelfBatchNamedOptionPlaceholderRow()
                }
            } else if let createTitle {
                Button(action: onCreate) {
                    BookshelfBatchNamedOptionCreateRow(
                        title: createTitle,
                        optionName: optionName,
                        isCreating: isCreating,
                        showsDivider: !options.isEmpty || hasCreateError
                    )
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
                .transition(.opacity)
            }

            if !isLoading, hasCreateError, let createError {
                Text(createError)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.feedbackError)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.contentEdge)
                    .padding(.vertical, Spacing.half)
            }

            if !isLoading && !hasLoadError {
                if options.isEmpty {
                    if createTitle == nil {
                        BookshelfBatchNamedOptionEmptyRow(text: emptyText)
                    }
                } else {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        Button {
                            onToggle(option.id)
                        } label: {
                            rowContent(
                                option,
                                selectedIDs.contains(option.id),
                                index < options.count - 1
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.half)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
    }

    private var hasCreateError: Bool {
        guard let createError else { return false }
        return !createError.isEmpty
    }

    private var hasLoadError: Bool {
        guard let loadErrorMessage else { return false }
        return !loadErrorMessage.isEmpty
    }
}

/// 命名选项读取中的面板内反馈，复用全局延迟 Loading 策略后的可视态。
private struct BookshelfBatchNamedOptionLoadingRow: View {
    let optionName: String

    var body: some View {
        LoadingStateView("正在加载\(optionName)…", style: .inline)
            .frame(maxWidth: .infinity, minHeight: 56)
    }
}

/// 命名选项读取延迟窗口内的占位行，避免快速读取时闪出文字。
private struct BookshelfBatchNamedOptionPlaceholderRow: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 56)
    }
}

/// 命名选项读取失败时的面板内错误文案。
private struct BookshelfBatchNamedOptionLoadErrorRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.body)
            .foregroundStyle(Color.feedbackError)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.half)
            .frame(minHeight: 56)
    }
}

/// 命名选项列表中的创建入口行，作为搜索结果的一部分出现。
private struct BookshelfBatchNamedOptionCreateRow: View {
    let title: String
    let optionName: String
    let isCreating: Bool
    let showsDivider: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "plus.circle.fill")
                .font(AppTypography.body)
                .foregroundStyle(Color.brand)

            Text(isCreating ? "正在创建“\(title)”" : "创建“\(title)”")
                .font(AppTypography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.base)
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.half)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) {
            BookshelfBatchInsetDivider()
                .opacity(showsDivider ? 1 : 0)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(isCreating ? "正在创建\(optionName) \(title)" : "创建\(optionName) \(title)")
    }
}

/// 移组列表中的分组选项行，以封面拼图辅助识别目标分组。
private struct BookshelfBatchMoveGroupOptionRow: View {
    let option: BookshelfMoveGroupOption
    let isSelected: Bool
    let showsDivider: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            BookshelfBatchGroupCoverPreview(covers: option.representativeCovers)

            VStack(alignment: .leading, spacing: Spacing.micro) {
                Text(option.title)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(option.bookCount)本")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            XMSelectionIndicator(
                style: .checkbox,
                isSelected: isSelected,
                font: AppTypography.bodyMedium
            )
            .frame(width: 30, height: 30)
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.half)
        .frame(minHeight: 68)
        .overlay(alignment: .bottom) {
            BookshelfBatchInsetDivider(
                leadingInset: Spacing.contentEdge
                    + BookshelfBatchGroupCoverPreviewLayout.width
                    + Spacing.base
            )
            .opacity(showsDivider ? 1 : 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(option.title)，\(option.bookCount)本，\(isSelected ? "已选中" : "未选中")")
    }
}

/// 移组行左侧的小型 2x2 代表封面预览。
private struct BookshelfBatchGroupCoverPreview: View {
    let covers: [String]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(Color.surfaceNested)

            if covers.isEmpty {
                Image(systemName: "books.vertical")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
            } else {
                coverGrid
            }
        }
        .frame(
            width: BookshelfBatchGroupCoverPreviewLayout.width,
            height: BookshelfBatchGroupCoverPreviewLayout.height
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
    }

    private var coverGrid: some View {
        LazyVGrid(
            columns: BookshelfBatchGroupCoverPreviewLayout.columns,
            spacing: BookshelfBatchGroupCoverPreviewLayout.spacing
        ) {
            ForEach(0..<BookshelfBatchGroupCoverPreviewLayout.coverSlotCount, id: \.self) { index in
                let cover = cover(at: index)
                XMBookCover.fixedSize(
                    width: BookshelfBatchGroupCoverPreviewLayout.cellWidth,
                    height: BookshelfBatchGroupCoverPreviewLayout.cellHeight,
                    urlString: cover,
                    cornerRadius: CornerRadius.inlayTiny,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    placeholderIconSize: cover.isEmpty ? .hidden : .small,
                    surfaceStyle: .plain
                )
            }
        }
        .padding(BookshelfBatchGroupCoverPreviewLayout.innerPadding)
    }

    private func cover(at index: Int) -> String {
        guard covers.indices.contains(index) else { return "" }
        return covers[index]
    }
}

/// 移组分组封面预览的私有尺寸，保持列表行紧凑且不影响全局 token。
private enum BookshelfBatchGroupCoverPreviewLayout {
    static let width: CGFloat = 42
    static let height: CGFloat = 56
    static let spacing: CGFloat = 2
    static let innerPadding: CGFloat = 3
    static let coverSlotCount = 4

    static let cellWidth: CGFloat = (width - innerPadding * 2 - spacing) / 2
    static let cellHeight: CGFloat = (height - innerPadding * 2 - spacing) / 2

    static var columns: [GridItem] {
        [
            GridItem(.fixed(cellWidth), spacing: spacing),
            GridItem(.fixed(cellWidth), spacing: spacing)
        ]
    }
}

/// 命名选项列表中的选项行，复用书架选择态的动画 checkbox 样式。
private struct BookshelfBatchNamedOptionRow: View {
    let title: String
    let isSelected: Bool
    let showsDivider: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.base)

            XMSelectionIndicator(
                style: .checkbox,
                isSelected: isSelected,
                font: AppTypography.bodyMedium
            )
            .frame(width: 30, height: 30)
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.half)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) {
            BookshelfBatchInsetDivider()
                .opacity(showsDivider ? 1 : 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(isSelected ? "已选中" : "未选中")")
    }
}

/// 命名选项列表空态行，保持和普通列表项一致的适中行高。
private struct BookshelfBatchNamedOptionEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.body)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.half)
            .frame(minHeight: 56)
    }
}

/// 批量命名选项列表内缩分割线，避免分隔线贴边造成紧张感。
private struct BookshelfBatchInsetDivider: View {
    var leadingInset: CGFloat = Spacing.contentEdge
    var trailingInset: CGFloat = Spacing.contentEdge

    var body: some View {
        Rectangle()
            .fill(Color.divider)
            .frame(height: CardStyle.borderWidth)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
    }
}

/// 批量编辑面板新增输入行，统一输入、提交与错误反馈语义。
private struct BookshelfBatchCreateField: View {
    @Binding var text: String
    let placeholder: String
    let actionTitle: String
    let isProcessing: Bool
    let errorMessage: String?
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                TextField(placeholder, text: $text)
                    .font(AppTypography.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, Spacing.base)
                    .frame(minHeight: 46)
                    .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))

                Button(actionTitle, action: onSubmit)
                    .font(AppTypography.subheadlineSemibold)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brand)
                    .disabled(trimmedText.isEmpty || isProcessing)
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.feedbackError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 批量面板内的空结果提示行。
private struct BookshelfBatchEmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.body)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 52)
    }
}

/// 批量来源面板分区标题行。
private struct BookshelfBatchSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AppTypography.captionSemibold)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Spacing.half)
            .padding(.bottom, Spacing.tight)
    }
}

/// 二级列表批量阅读状态 Sheet，读完状态要求选择评分。
struct BookshelfBatchReadStatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedStatusID: Int64
    @State private var changedAt = Date()
    @State private var ratingValue: Double = 0

    let options: [BookEditorNamedOption]
    let selectedCount: Int
    let onConfirm: (Int64, Date, Int64?) -> Void

    /// 构建批量阅读状态 Sheet，优先使用单本或上下文状态，否则回退到“在读”。
    init(
        options: [BookEditorNamedOption],
        selectedCount: Int,
        initialStatusID: Int64?,
        initialChangedAt: Date?,
        initialRatingScore: Int64?,
        onConfirm: @escaping (Int64, Date, Int64?) -> Void
    ) {
        self.options = options
        self.selectedCount = selectedCount
        self.onConfirm = onConfirm
        let optionIDs = Set(options.map(\.id))
        let preferredID = initialStatusID.flatMap { optionIDs.contains($0) ? $0 : nil }
            ?? options.first(where: { $0.id == BookEntryReadingStatus.reading.rawValue })?.id
            ?? options.first?.id
            ?? 0
        self._selectedStatusID = State(initialValue: preferredID)
        self._changedAt = State(initialValue: initialChangedAt ?? Date())
        let initialRating = min(max(Double(initialRatingScore ?? 0) / 10.0, 0), 5)
        self._ratingValue = State(initialValue: initialRating)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读状态") {
                    ForEach(options) { option in
                        Button {
                            selectedStatusID = option.id
                        } label: {
                            BookshelfBatchOptionRow(
                                title: option.title,
                                isSelected: selectedStatusID == option.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("状态时间") {
                    DatePicker(
                        "变更时间",
                        selection: $changedAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                if isFinished {
                    Section {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            HStack {
                                Text("评分")
                                    .font(AppTypography.body)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Text(ratingTitle)
                                    .font(AppTypography.body)
                                    .foregroundStyle(ratingValue > 0 ? Color.textPrimary : Color.feedbackError)
                            }

                            Slider(value: $ratingValue, in: 0...5, step: 0.5)
                                .accessibilityLabel("评分")
                        }
                    } footer: {
                        Text("读完状态会同步评分，并把阅读进度推进到终点。")
                            .font(AppTypography.caption)
                    }
                }
            }
            .navigationTitle("设置状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onConfirm(selectedStatusID, changedAt, ratingScore)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var isFinished: Bool {
        selectedStatusID == BookEntryReadingStatus.finished.rawValue
    }

    private var canSubmit: Bool {
        selectedStatusID != 0 && (!isFinished || ratingScore != nil)
    }

    private var ratingScore: Int64? {
        guard isFinished else { return nil }
        let score = Int64((ratingValue * 10).rounded())
        return score > 0 ? score : nil
    }

    private var ratingTitle: String {
        guard ratingValue > 0 else { return "未评分" }
        return String(format: "%.1f 星", ratingValue)
    }
}

/// 批量编辑 Sheet 中的统一单选/多选行视觉。
private struct BookshelfBatchOptionRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)

            Spacer(minLength: Spacing.compact)

            XMSelectionIndicator(
                style: .checkbox,
                isSelected: isSelected,
                font: AppTypography.body
            )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(isSelected ? "已选中" : "未选中")")
    }
}
