/**
 * [INPUT]: 依赖导入资料快照、现有分组标签选项、XMSheetScaffold 与原生设置控件
 * [OUTPUT]: 提供确认前不写书库的书籍资料编辑 Sheet
 * [POS]: Views/Personal/DataImport 的功能私有编辑表单，提交由导入会话负责
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 编辑只发生在 Sheet 局部副本中，确认后交回导入草稿。
struct NoteImportBookEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft: NoteImportBookMetadata
    @State private var showsCoverPicker = false
    @State private var showsCoverURL = false
    @State private var coverInput = ""
    @State private var showsDiscard = false
    private let embedded: Bool
    private let original: NoteImportBookMetadata
    private let options: BookEditorOptions?
    private let onConfirm: (NoteImportBookMetadata) -> Void

    /// 建立独立编辑副本，避免取消 Sheet 时需要回滚数据库。
    init(metadata: NoteImportBookMetadata, options: BookEditorOptions?, embedded: Bool = false, onConfirm: @escaping (NoteImportBookMetadata) -> Void) {
        self.embedded = embedded
        _draft = State(initialValue: metadata)
        original = metadata
        self.options = options
        self.onConfirm = onConfirm
    }

    var body: some View {
        Group {
            if embedded {
                ScrollView { fields }
                    .background(Color.surfaceSheet)
                    .navigationTitle("其他资料")
                    .navigationBarTitleDisplayMode(.inline)
                    .onChange(of: draft) { _, value in onConfirm(value) }
            } else {
                XMSheetScaffold(title: "书籍资料", onClose: requestClose,
                    isConfirmationDisabled: draft.validationMessage != nil,
                    confirmationAction: confirm) {
                    fields
                }
            }
        }
        .interactiveDismissDisabled(!embedded && draft != original)
        .confirmationDialog("放弃本次资料修改？", isPresented: $showsDiscard) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
        .sheet(isPresented: $showsCoverPicker) {
            BookPickerView(configuration: .init(title: "选择封面", scope: .online, selectionMode: .single,
                onlineSelectionPolicy: .returnRemoteSelection, defaultQuery: draft.title)) { result in
                if case .single(.remote(let result)) = result { draft.coverURL = result.seed.coverURL }
                showsCoverPicker = false
            }
        }
        .xmSystemAlert(isPresented: $showsCoverURL, descriptor: .init(title: "封面地址",
            actions: [.init(title: "取消", role: .cancel) {}, .init(title: "确认") { draft.coverURL = coverInput.trimmingCharacters(in: .whitespacesAndNewlines) }],
            textFields: [.init(text: $coverInput, placeholder: "https://")]))
        .tint(Color.textPrimary)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            coverHeader
            XMSettingsGroup {
                VStack(spacing: Spacing.none) {
                    textField("书名", text: $draft.title)
                    XMSettingsDivider()
                    textField("作者", text: $draft.author)
                    XMSettingsDivider()
                    textField("译者", text: $draft.translator)
                    XMSettingsDivider()
                    textField("出版社", text: $draft.press)
                    XMSettingsDivider()
                    textField("ISBN", text: $draft.isbn)
                    XMSettingsDivider()
                    textField("出版日期", text: $draft.publicationDate)
                }
            }
            XMSettingsGroup {
                VStack(spacing: Spacing.none) {
                    XMSettingsValueMenuRow(title: "阅读状态", value: statusTitle,
                        options: BookEntryReadingStatus.allCases, selection: BookEntryReadingStatus(rawValue: draft.readingStatusID) ?? .reading,
                        optionTitle: { $0.title }, optionImage: { _ in nil }, onSelect: { draft.readingStatusID = $0.rawValue })
                    XMSettingsDivider()
                    NavigationLink {
                        NoteImportNamesEditor(title: "分组", names: groupBinding, options: options?.groups.map(\.title) ?? [], multiple: false)
                    } label: { NoteImportFormValue(title: "分组", value: draft.groupName.isEmpty ? "未分组" : draft.groupName, showsDisclosure: true) }
                    XMSettingsDivider()
                    NavigationLink {
                        NoteImportNamesEditor(title: "标签", names: $draft.tagNames, options: options?.tags.map(\.title) ?? [], multiple: true)
                    } label: { NoteImportFormValue(title: "标签", value: draft.tagNames.isEmpty ? "未设置" : draft.tagNames.joined(separator: "、"), showsDisclosure: true) }
                }
            }
            XMSettingsGroup {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text("作者简介").font(AppTypography.body).foregroundStyle(Color.textPrimary)
                    TextField("作者简介", text: $draft.authorIntro, axis: .vertical)
                        .font(AppTypography.subheadline).lineLimit(3...8)
                    XMSettingsDivider()
                    Text("摘要").font(AppTypography.body).foregroundStyle(Color.textPrimary)
                    TextField("摘要", text: $draft.summary, axis: .vertical)
                        .font(AppTypography.subheadline).lineLimit(3...12)
                }
                .padding(.vertical, Spacing.cozy)
            }
            if let issue = draft.validationMessage {
                Text(issue).font(AppTypography.footnote).foregroundStyle(Color.feedbackWarning)
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.contentEdge)
    }

    private var coverHeader: some View {
        HStack(spacing: Spacing.base) {
            XMBookCover.fixedWidth(44, urlString: draft.coverURL, cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline), placeholderIconSize: .medium)
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(draft.title.isEmpty ? "未命名书籍" : draft.title).font(AppTypography.bodyMedium).lineLimit(2)
                Menu {
                    Button("搜索封面") { showsCoverPicker = true }
                    Button("输入封面地址") { coverInput = draft.coverURL; showsCoverURL = true }
                    Button("移除封面") { draft.coverURL = "" }.disabled(draft.coverURL.isEmpty)
                } label: { NoteImportMenuLabel(title: "更换封面") }
                .xmMenuNeutralTint()
            }
        }
    }

    private var statusTitle: String { (BookEntryReadingStatus(rawValue: draft.readingStatusID) ?? .reading).title }
    private var groupBinding: Binding<[String]> {
        Binding(get: { draft.groupName.isEmpty ? [] : [draft.groupName] }, set: { draft.groupName = $0.first ?? "" })
    }

    /// 原生输入承接动态字体，多行值不靠缩小字体压缩。
    private func textField(_ title: String, text: Binding<String>) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(title).font(AppTypography.body).foregroundStyle(Color.textPrimary)
                    metadataInput(title, text: text)
                }
            } else {
                HStack(spacing: Spacing.base) {
                    Text(title).font(AppTypography.body).foregroundStyle(Color.textPrimary).fixedSize()
                    metadataInput(title, text: text).multilineTextAlignment(.trailing)
                }
            }
        }
        .frame(minHeight: InteractionMetrics.minimumTouchTarget, alignment: .leading)
        .padding(.vertical, Spacing.compact)
    }

    /// 输入值沿用设置项的从属字号，不把字段标题升级为标题排版。
    private func metadataInput(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text, axis: .vertical)
            .font(AppTypography.subheadline).foregroundStyle(Color.textSecondary)
            .textInputAutocapitalization(.never)
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .accessibilityLabel(title)
    }

    /// 仅有局部资料修改时提示放弃，未编辑时直接关闭。
    private func requestClose() { if draft != original { showsDiscard = true } else { dismiss() } }
    /// 校验并交回资料草稿，由最终导入负责真正写入。
    private func confirm() {
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.validationMessage == nil else { return }
        onConfirm(draft)
        dismiss()
    }
}

/// 功能私有表单导航行，值在辅助字号下自然换行。
struct NoteImportFormValue: View {
    let title: String
    let value: String
    var showsDisclosure = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.compact) { titleText; trailingValue }
            } else {
                HStack(spacing: Spacing.base) { titleText; Spacer(minLength: Spacing.base); trailingValue }
            }
        }
        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
        .padding(.vertical, Spacing.compact)
        .contentShape(Rectangle())
    }
    private var titleText: some View { Text(title).font(AppTypography.body).foregroundStyle(Color.textPrimary) }
    private var valueText: some View { Text(value).font(AppTypography.subheadline).foregroundStyle(Color.textSecondary) }
    private var trailingValue: some View {
        HStack(spacing: Spacing.cozy) {
            valueText
            if showsDisclosure {
                Image(systemName: "chevron.right").font(AppTypography.footnote).foregroundStyle(Color.iconSecondary).accessibilityHidden(true)
            }
        }
    }
}

/// 名称选择只编辑本地数组，新建分组/标签直到最终导入才进入数据库。
private struct NoteImportNamesEditor: View {
    let title: String
    @Binding var names: [String]
    let options: [String]
    let multiple: Bool
    @State private var newName = ""
    private var allNames: [String] { Array(Set(options + names)).sorted() }
    var body: some View {
        List {
            Section {
                HStack {
                    TextField("新名称", text: $newName).onSubmit(addName)
                    Button("添加", action: addName).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section {
                Button("不设置") { names = [] }
                ForEach(allNames, id: \.self) { name in
                    Button { toggle(name) } label: {
                        HStack {
                            Text(name).foregroundStyle(Color.textPrimary)
                            Spacer()
                            if names.contains(name) { Image(systemName: "checkmark").foregroundStyle(Color.textPrimary) }
                        }
                        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                    }
                    .accessibilityAddTraits(names.contains(name) ? .isSelected : [])
                }
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .tint(Color.textPrimary)
    }
    /// 切换草稿中的名称选择，不创建或移除数据库实体。
    private func toggle(_ value: String) {
        if names.contains(value) { names.removeAll { $0 == value } }
        else if multiple { names.append(value) } else { names = [value] }
    }
    /// 去除名称首尾空白并加入本地选择，最终提交前不写仓储。
    private func addName() {
        let value = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !names.contains(value) { if multiple { names.append(value) } else { names = [value] } }
        newName = ""
    }
}
