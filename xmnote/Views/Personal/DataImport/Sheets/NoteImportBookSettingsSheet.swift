/**
 * [INPUT]: 依赖导入会话局部副本、BookPickerView、资料表单与时长评估
 * [OUTPUT]: 提供一个确认边界内的资料、存放目标、内容与时长设置
 * [POS]: Views/Personal/DataImport 的单本编辑入口，子页不直接改主会话
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import SwiftUI

/// 一个局部会话覆盖所有子页；只有顶层确认才合入父会话。
struct NoteImportBookSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: NoteImportPreviewViewModel
    let bookID: UUID
    @State private var session: NoteImportPreviewViewModel
    @State private var showsDiscard = false
    /// 复制目标上下文，取消无需数据库回滚。
    init(model: NoteImportPreviewViewModel, bookID: UUID) {
        self.model = model; self.bookID = bookID
        _session = State(initialValue: model.editorSession())
    }
    private var book: NoteImportPreviewBook? { session.books.first { $0.id == bookID } }
    var body: some View {
        XMSheetScaffold(title: "书籍设置", onClose: requestClose,
            isConfirmationDisabled: session.isLocked || session.isAssessing || book.map { session.metadata(for: $0).validationMessage != nil } == true,
            confirmationAction: { model.applyEditorSession(session, bookID: bookID); dismiss() }) {
            if let book {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    header(book)
                    XMSettingsGroup {
                        VStack(spacing: Spacing.none) {
                            NavigationLink { NoteImportDestinationPage(model: session, bookID: bookID) } label: {
                                NoteImportFormValue(title: "存入书籍", value: book.placement == .unresolved ? "请选择" : book.targetID == nil ? "新建书籍" : session.metadata(for: book).title, showsDisclosure: true)
                            }
                            XMSettingsDivider()
                            field("书名", path: \.title)
                            XMSettingsDivider()
                            field("作者", path: \.author)
                            XMSettingsDivider()
                            NavigationLink {
                                NoteImportBookEditorSheet(metadata: session.metadata(for: book), options: session.editorOptions, embedded: true) {
                                    session.updateMetadata($0, bookID: bookID)
                                }
                            } label: { NoteImportFormValue(title: "其他资料", value: "", showsDisclosure: true) }
                        }
                    }
                    XMSettingsGroup {
                        VStack(spacing: Spacing.none) {
                            NavigationLink { NoteImportContentPreviewView(model: session, bookID: bookID) } label: {
                                NoteImportFormValue(title: "导入内容", value: book.contentTitle, showsDisclosure: true)
                            }
                            if book.sourceSeconds != nil {
                                XMSettingsDivider()
                                NavigationLink { NoteImportDurationPage(model: session, bookID: bookID) } label: {
                                    NoteImportFormValue(title: "阅读时长", value: durationTitle(book), showsDisclosure: true)
                                }
                            }
                        }
                    }
                    if let error = session.errorMessage {
                        Text(error).font(AppTypography.footnote).foregroundStyle(Color.feedbackWarning)
                    }
                }
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, Spacing.screenEdge).padding(.bottom, Spacing.contentEdge)
                .disabled(session.isLocked)
            }
        }
        .interactiveDismissDisabled(session.hasUnsavedChanges)
        .confirmationDialog("放弃本次修改？", isPresented: $showsDiscard) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
        .tint(Color.textPrimary)
        .task { await session.refreshDurations() }
    }
    /// 紧凑封面与完整名称用于识别，封面操作归入已有资料表单。
    private func header(_ book: NoteImportPreviewBook) -> some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            XMBookCover.fixedWidth(44, urlString: session.metadata(for: book).coverURL, cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline), placeholderIconSize: .medium)
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(session.metadata(for: book).title).font(AppTypography.bodyMedium)
                NavigationLink {
                    NoteImportBookEditorSheet(metadata: session.metadata(for: book), options: session.editorOptions, embedded: true) {
                        session.updateMetadata($0, bookID: bookID)
                    }
                } label: { Text("更换封面").font(AppTypography.footnote).foregroundStyle(Color.textSecondary).frame(minHeight: InteractionMetrics.minimumTouchTarget) }
            }
        }
    }
    /// 根级字段直接编辑局部共享资料，保留目标与编辑对象一致。
    private func field(_ title: String, path: WritableKeyPath<NoteImportBookMetadata, String>) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(title).font(AppTypography.body)
                    TextField(title, text: metadataBinding(path)).font(AppTypography.subheadline).accessibilityLabel(title)
                }
            } else {
                HStack(spacing: Spacing.base) {
                    Text(title).font(AppTypography.body).fixedSize()
                    TextField(title, text: metadataBinding(path)).font(AppTypography.subheadline)
                        .multilineTextAlignment(.trailing).accessibilityLabel(title)
                }
            }
        }.frame(minHeight: InteractionMetrics.minimumTouchTarget).padding(.vertical, Spacing.compact)
    }
    /// 无本地时长时表达导入开关，只有真实冲突才使用合并或保留措辞。
    private func durationTitle(_ book: NoteImportPreviewBook) -> String {
        guard let choice = session.durationChoice(for: book), let policy = choice.policy else { return "待选择" }
        if choice.assessment.localCount == 0 { return policy == .keep ? "不导入时长" : "导入时长" }
        return policy.title
    }
    /// Binding 写入局部会话，不调用已有书籍编辑器的即时保存。
    private func metadataBinding(_ path: WritableKeyPath<NoteImportBookMetadata, String>) -> Binding<String> {
        Binding(get: { book.map { session.metadata(for: $0)[keyPath: path] } ?? "" }, set: { value in
            guard let book else { return }
            var metadata = session.metadata(for: book); metadata[keyPath: path] = value
            session.updateMetadata(metadata, bookID: bookID)
        })
    }
    /// 无修改直接退出，有修改沿用项目放弃保护。
    private func requestClose() { if session.hasUnsavedChanges { showsDiscard = true } else { dismiss() } }
}

/// 存放目标是独立设置，现有选书页承担搜索和本地单选。
private struct NoteImportDestinationPage: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: NoteImportPreviewViewModel
    let bookID: UUID
    @State private var showsPicker = false
    private var book: NoteImportPreviewBook? { model.books.first { $0.id == bookID } }
    var body: some View {
        List {
            Button { model.chooseNewBook(bookID); dismiss() } label: {
                HStack {
                    Text("新建书籍")
                    Spacer()
                    if book?.placement == .newBook { Image(systemName: "checkmark") }
                }.frame(minHeight: InteractionMetrics.minimumTouchTarget)
            }
            Button { showsPicker = true } label: {
                NoteImportFormValue(title: "选择已有书籍", value: book.flatMap { $0.targetID == nil ? nil : model.metadata(for: $0).title } ?? "", showsDisclosure: true)
            }
            if let error = model.errorMessage { Text(error).font(AppTypography.footnote).foregroundStyle(Color.feedbackWarning) }
        }
        .navigationTitle("存入书籍").navigationBarTitleDisplayMode(.inline).tint(Color.textPrimary)
        .disabled(model.isLocked)
        .sheet(isPresented: $showsPicker) {
            BookPickerView(configuration: .init(title: "选择已有书籍", scope: .local, selectionMode: .single,
                allowsCreationFlow: false, defaultQuery: book?.source.name ?? "")) { result in
                showsPicker = false
                if case .single(.local(let value)) = result {
                    Task {
                        await model.chooseExistingBook(bookID, targetID: value.id)
                        if book?.targetID == value.id { dismiss() }
                    }
                }
            }
        }
    }
}

/// 来源和本地总额与三项决定同屏，选择后显示相同运算得到的结果。
private struct NoteImportDurationPage: View {
    @Bindable var model: NoteImportPreviewViewModel
    let bookID: UUID
    @State private var applyToOthers = false
    private var book: NoteImportPreviewBook? { model.books.first { $0.id == bookID } }
    var body: some View {
        List {
            if let book, let choice = model.durationChoice(for: book) {
                Section {
                    valueRow("本地", seconds: choice.assessment.localSeconds)
                    valueRow("来源", seconds: choice.assessment.sourceSeconds ?? 0)
                }
                Section {
                    ForEach(NoteImportDurationPolicy.allCases.filter { $0 != .replace || choice.assessment.localCount > 0 }, id: \.self) { policy in
                        Button { model.chooseDuration(policy, bookID: bookID, applyToOthers: applyToOthers) } label: {
                            HStack(alignment: .top, spacing: Spacing.base) {
                                VStack(alignment: .leading, spacing: Spacing.compact) {
                                    Text(choice.assessment.localCount == 0 ? (policy == .keep ? "不导入时长" : "导入时长") : policy.title).font(AppTypography.body)
                                    Text(policy == .merge && choice.assessment.localCount == 0 ? "导入来源提供的阅读时长。" : description(policy, book: book)).font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
                                }
                                Spacer()
                                if choice.policy == policy { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                            .frame(minHeight: InteractionMetrics.minimumTouchTarget).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(policy == .replace && (choice.assessment.hasActiveTimer || choice.assessment.sourceSeconds == nil || choice.assessment.localCount == 0))
                        .accessibilityAddTraits(choice.policy == policy ? .isSelected : [])
                    }
                } footer: {
                    if choice.assessment.hasActiveTimer { Text("本书还有未完成的计时，处理后才能替换。") }
                }
                if choice.assessment.needsDecision {
                    Section {
                        Toggle("应用到本次其余待处理书籍", isOn: $applyToOthers)
                            .onChange(of: applyToOthers) { _, value in
                                if value, let policy = choice.policy { model.chooseDuration(policy, bookID: bookID, applyToOthers: true) }
                            }
                    }
                }
                if let policy = choice.policy {
                    Section { valueRow("导入后时长", seconds: choice.assessment.resultSeconds(for: policy)) }
                }
            } else {
                Section {
                    Text(book?.issue ?? "无法读取阅读时长").foregroundStyle(Color.textSecondary)
                    Button("重新读取") { Task { await model.refreshDurations() } }
                }
            }
        }
        .navigationTitle("阅读时长").navigationBarTitleDisplayMode(.inline)
        .tint(Color.textPrimary).disabled(model.isAssessing)
    }
    /// 来源数值与本地数值统一按真实秒数显示。
    private func valueRow(_ title: String, seconds: Int64) -> some View {
        NoteImportFormValue(title: title, value: NoteImportDurationMerge.text(seconds))
    }
    /// 说明随来源规则变化，不把按日补差误写成简单相加。
    private func description(_ policy: NoteImportDurationPolicy, book: NoteImportPreviewBook) -> String {
        switch policy {
        case .merge:
            if !(book.source.wereadReadingDurations ?? []).isEmpty { return "保留本地记录，更新微信读书时长。跨来源重叠可能重复计时。" }
            if !(book.source.fuzzyReadingDurations ?? []).isEmpty { return "保留本地记录，按日补足来源时长。" }
            return "保留本地记录，跳过起止时间相同的记录。部分重叠可能重复计时。"
        case .replace: return "清空本书已有时长记录，再导入来源时长。"
        case .keep: return "本次不导入来源时长，其他内容照常导入。"
        }
    }
}
