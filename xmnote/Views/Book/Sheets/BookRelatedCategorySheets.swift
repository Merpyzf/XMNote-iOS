/**
 * [INPUT]: 依赖 BookContentCategoryOption、XMSheetScaffold、XMSystemAlert 与设计令牌，接收书籍详情 ViewModel 提供的分类写入和异步占位书恢复回调
 * [OUTPUT]: 对外提供带顶部原位确认反馈的 BookRelatedPlaceholderSheet、BookRelatedCategoryPickerSheet 与带中性操作菜单的 BookRelatedCategoryManagementSheet
 * [POS]: Book 模块业务 Sheet，分别承接新建相关内容的分类选择和书内/全局相关分类管理
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 在线相关书籍占位记录的可用查看页，允许用户显式恢复到书架后进入完整详情与编辑链路。
struct BookRelatedPlaceholderSheet: View {
    let item: BookContentRelatedItem
    let onEdit: () -> Void
    let onRestore: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isRestoring = false
    @State private var restoreErrorMessage: String?
    @State private var restoreTask: Task<Void, Never>?

    var body: some View {
        XMSheetScaffold(
            title: "相关书籍",
            onClose: { dismiss() },
            isInteractionLocked: isRestoring,
            isConfirming: isRestoring,
            confirmationAction: restore
        ) {
            VStack(alignment: .leading, spacing: Spacing.double) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    XMBookCover.fixedWidth(
                        BookRelatedCategorySheetLayout.placeholderCoverWidth,
                        urlString: item.coverURL,
                        cornerRadius: CornerRadius.inlayHairline,
                        border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                        placeholderIconSize: .medium,
                        surfaceStyle: .spine
                    )
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Text(item.title.isEmpty ? "未命名书籍" : item.title)
                            .font(AppTypography.headlineSemibold)
                            .foregroundStyle(Color.textPrimary)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .font(AppTypography.subheadline)
                                .foregroundStyle(Color.textSecondary)
                        }
                        Text("这是一条相关引用，尚未加入书架")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }

                Button {
                    dismiss()
                    onEdit()
                } label: {
                    Label("编辑书籍资料", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let restoreErrorMessage {
                    XMInlineStatusBanner(
                        "加入书架失败：\(restoreErrorMessage)",
                        tone: .error
                    )
                }

                Text("点击右上角确认可加入书架；也可以直接修改引用资料。加入书架后还能继续管理阅读状态、分组和标签，当前相关关系会保留。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(Spacing.screenEdge)
        }
        .presentationDetents([.medium])
        .onDisappear {
            restoreTask?.cancel()
            restoreTask = nil
        }
    }

    /// 在 Sheet 生命周期内执行恢复；确认期间锁定关闭与下滑，失败保留当前上下文供用户重试。
    private func restore() {
        guard !isRestoring else { return }
        isRestoring = true
        restoreErrorMessage = nil
        restoreTask = Task { @MainActor in
            defer {
                isRestoring = false
                restoreTask = nil
            }
            do {
                try await onRestore()
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                restoreErrorMessage = error.localizedDescription
            }
        }
    }
}

/// 新建普通相关内容前的分类选择 Sheet；管理页在同一 NavigationStack 内 push，返回后保留选择现场。
struct BookRelatedCategoryPickerSheet<ManagementDestination: View>: View {
    let categories: [BookContentCategoryOption]
    let onSelect: (BookContentCategoryOption) -> Void
    @ViewBuilder let managementDestination: () -> ManagementDestination

    @Environment(\.dismiss) private var dismiss
    @State private var path: [BookRelatedCategoryPickerRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if categories.isEmpty {
                    XMContentStateView(
                        role: .empty,
                        title: "没有可用分类",
                        systemImage: "square.grid.2x2"
                    )
                        .padding(Spacing.screenEdge)
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: Spacing.base) {
                            ForEach(categories) { category in
                                categoryButton(category)
                            }
                        }
                        .padding(Spacing.screenEdge)
                    }
                }
            }
            .background(Color.surfacePage)
            .navigationTitle("选择相关分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Color.textSecondary)
                    .accessibilityLabel("关闭")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        path.append(.management)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("管理分类")
                }
            }
            .navigationDestination(for: BookRelatedCategoryPickerRoute.self) { route in
                switch route {
                case .management:
                    managementDestination()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: Spacing.base),
            GridItem(.flexible(), spacing: Spacing.base)
        ]
    }

    private func categoryButton(_ category: BookContentCategoryOption) -> some View {
        Button {
            dismiss()
            onSelect(category)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text(category.title.isEmpty ? "未命名分类" : category.title)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(category.isGlobal ? "全部书籍" : "当前书")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: BookRelatedCategorySheetLayout.optionMinHeight, alignment: .leading)
            .padding(Spacing.contentEdge)
            .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.title)，\(category.isGlobal ? "全部书籍" : "当前书")")
    }
}

private enum BookRelatedCategoryPickerRoute: Hashable {
    case management
}

/// 描述分类管理页所处的导航上下文，避免在已有 NavigationStack 中重复包裹导航容器。
enum BookRelatedCategoryManagementPresentation: Equatable {
    case sheet
    case navigationDestination
}

/// 相关分类管理 Sheet，固定默认分类只允许隐藏/显示，自定义分类可编辑、删除并整体排序。
struct BookRelatedCategoryManagementSheet: View {
    let categories: [BookContentCategoryOption]
    let isWriting: Bool
    let actionErrorMessage: String?
    let presentation: BookRelatedCategoryManagementPresentation
    let onCreate: (String, BookContentCategoryScope) -> Void
    let onRename: (Int64, String) -> Void
    let onDelete: (Int64) -> Void
    let onSetHidden: (Int64, Bool) -> Void
    let onReorder: ([Int64]) -> Void
    let onConsumeError: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editMode: EditMode = .inactive
    @State private var orderedIDs: [Int64] = []
    @State private var alert: BookRelatedCategoryAlert?
    @State private var nameDraft = ""

    var body: some View {
        Group {
            if presentation == .sheet {
                NavigationStack {
                    managementContent
                }
            } else {
                managementContent
            }
        }
        .interactiveDismissDisabled(isWriting)
        .onAppear(perform: synchronizeOrder)
        .onChange(of: categories) { _, _ in synchronizeOrder() }
        .onChange(of: actionErrorMessage) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            synchronizeOrder()
            alert = .error(message: newValue)
        }
        .xmSystemAlert(item: $alert, descriptor: alertDescriptor)
    }

    private var managementContent: some View {
        List {
            Section {
                Text("固定默认分类可隐藏但不可重命名或删除；“全部书籍”分类的编辑、删除与排序会影响其他书籍。")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }

            Section("分类") {
                ForEach(orderedCategories) { category in
                    categoryRow(category)
                }
                .onMove(perform: moveCategories)
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .background(Color.surfacePage)
        .navigationTitle("相关分类")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentation == .sheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Color.textSecondary)
                    .disabled(isWriting)
                    .accessibilityLabel("关闭")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("新增", systemImage: "plus", action: presentCreateAlert)
                    .disabled(isWriting || editMode.isEditing)
                EditButton()
                    .disabled(isWriting || categories.count < 2)
            }
        }
    }

    private var orderedCategories: [BookContentCategoryOption] {
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let ordered = orderedIDs.compactMap { byID[$0] }
        let knownIDs = Set(orderedIDs)
        return ordered + categories.filter { !knownIDs.contains($0.id) }
    }

    private func categoryRow(_ category: BookContentCategoryOption) -> some View {
        HStack(spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.micro) {
                HStack(spacing: Spacing.half) {
                    Text(category.title.isEmpty ? "未命名分类" : category.title)
                        .font(AppTypography.body)
                        .foregroundStyle(category.isHidden ? Color.textSecondary : Color.textPrimary)
                    if category.isHidden {
                        Text("已隐藏")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textHint)
                    }
                }

                Text(categoryScopeDescription(category))
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 0)

            if !editMode.isEditing {
                if category.isSystemDefault {
                    Button {
                        onSetHidden(category.id, !category.isHidden)
                    } label: {
                        Image(systemName: category.isHidden ? "eye" : "eye.slash")
                            .font(AppTypography.body)
                            .frame(minWidth: BookRelatedCategorySheetLayout.controlMinSize, minHeight: BookRelatedCategorySheetLayout.controlMinSize)
                    }
                    .disabled(isWriting)
                    .accessibilityLabel(category.isHidden ? "显示\(category.title)" : "隐藏\(category.title)")
                } else {
                    Menu {
                        Button("重命名", systemImage: "pencil") {
                            presentRenameAlert(category)
                        }
                        Button("删除", systemImage: "trash", role: .destructive) {
                            alert = .delete(category)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(AppTypography.body)
                            .frame(minWidth: BookRelatedCategorySheetLayout.controlMinSize, minHeight: BookRelatedCategorySheetLayout.controlMinSize)
                    }
                    .xmMenuNeutralTint()
                    .disabled(isWriting)
                    .accessibilityLabel("\(category.title)更多操作")
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private func categoryScopeDescription(_ category: BookContentCategoryOption) -> String {
        let scope = category.isGlobal ? "全部书籍" : "当前书"
        let kind = category.isSystemDefault ? "默认分类" : "自定义分类"
        return "\(scope) · \(kind) · \(category.contentCount) 条"
    }

    private func presentCreateAlert() {
        nameDraft = ""
        alert = .create
    }

    private func presentRenameAlert(_ category: BookContentCategoryOption) {
        nameDraft = category.title
        alert = .rename(category)
    }

    private func moveCategories(from source: IndexSet, to destination: Int) {
        var nextIDs = orderedCategories.map(\.id)
        nextIDs.move(fromOffsets: source, toOffset: destination)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
            orderedIDs = nextIDs
        }
        onReorder(nextIDs)
    }

    private func synchronizeOrder() {
        orderedIDs = categories.map(\.id)
    }

    private func alertDescriptor(_ alert: BookRelatedCategoryAlert) -> XMSystemAlertDescriptor {
        switch alert {
        case .create:
            return XMSystemAlertDescriptor(
                title: "新增相关分类",
                message: "选择“全部书籍”后，该分类会出现在每一本书中。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "当前书") {
                        onCreate(nameDraft, .currentBook)
                    },
                    XMSystemAlertAction(title: "全部书籍") {
                        onCreate(nameDraft, .allBooks)
                    }
                ],
                textFields: [categoryNameTextField(placeholder: "分类名称")]
            )
        case .rename(let category):
            return XMSystemAlertDescriptor(
                title: "重命名分类",
                message: category.isGlobal ? "该分类用于全部书籍，名称修改会跨书生效。" : nil,
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "完成") {
                        onRename(category.id, nameDraft)
                    }
                ],
                textFields: [categoryNameTextField(placeholder: category.title)]
            )
        case .delete(let category):
            return XMSystemAlertDescriptor(
                title: "删除相关分类",
                message: deleteMessage(category),
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "删除", role: .destructive) {
                        onDelete(category.id)
                    }
                ]
            )
        case .error(let message):
            return XMSystemAlertDescriptor(
                title: "操作未完成",
                message: message,
                actions: [
                    XMSystemAlertAction(title: "好") {
                        onConsumeError()
                    }
                ]
            )
        }
    }

    private func categoryNameTextField(placeholder: String) -> XMSystemAlertTextField {
        XMSystemAlertTextField(
            text: Binding(
                get: { nameDraft },
                set: { nameDraft = $0 }
            ),
            placeholder: placeholder,
            autocorrectionDisabled: true
        )
    }

    private func deleteMessage(_ category: BookContentCategoryOption) -> String {
        if category.isGlobal {
            return "“\(category.title)”用于全部书籍。删除后，其在所有书籍下的内容和图片都会标记为删除。"
        }
        return "将把“\(category.title)”及其中 \(category.contentCount) 条内容和图片标记为删除。"
    }
}

/// 分类管理中心弹窗状态，统一使用 XMSystemAlert 承接轻输入、删除确认与失败反馈。
private enum BookRelatedCategoryAlert: Identifiable {
    case create
    case rename(BookContentCategoryOption)
    case delete(BookContentCategoryOption)
    case error(message: String)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let category): "rename-\(category.id)"
        case .delete(let category): "delete-\(category.id)"
        case .error(let message): "error-\(message)"
        }
    }
}

private enum BookRelatedCategorySheetLayout {
    static let optionMinHeight: CGFloat = 56
    static let controlMinSize: CGFloat = InteractionMetrics.minimumTouchTarget
    static let placeholderCoverWidth: CGFloat = 88
}
