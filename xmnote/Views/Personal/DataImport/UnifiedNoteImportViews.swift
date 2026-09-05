/**
 * [INPUT]: 依赖 NoteImportDraftBook、NoteImportRepositoryProtocol 与 BookPickerView
 * [OUTPUT]: 提供解析草稿的来源标记、全来源书摘预览与确认导入
 * [POS]: Views/Personal/DataImport 的预览与提交层；输入准备由 NoteImportSourceScreen 独立持有
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Observation
import SwiftUI

extension Array where Element == NoteImportDraftBook {
    /// 在进入统一预览前设置来源身份，保留各导出版本共享的业务来源。
    func settingSource(for parserID: NoteImportParserID) -> [NoteImportDraftBook] {
        let sourceID: Int64 = switch parserID {
        case .kindle: 2; case .kindleApp: 3; case .wereadOld, .wereadPre830, .weread830: 4
        case .appleBooks: 5; case .moonReader: 6; case .duokan: 7; case .ireaderFile: 8
        case .doubanRead: 9; case .ireaderSelected: 10; case .jdReader: 11; case .booxOld, .booxNew: 12
        case .dangdang: 13; case .koreader: 14; case .reader163: 15; case .doubanApp: 16
        case .legado: 17; case .neatReader: 18; case .hanwang: 19; case .fanqie: 20
        case .dimo: 21; case .koodo: 23; case .ireaderEpub: 24; case .dedao: 25
        case .reeden: 26; case .readingo: 27
        }
        return map { source in var value = source; value.source = sourceID; return value }
    }
}

@MainActor @Observable
private final class UnifiedNoteImportPreviewModel {
    struct Book: Identifiable {
        let id = UUID()
        var draft: NoteImportDraftBook
        var isSelected: Bool
        var selectedNotes: Set<Int>
        var target: BookPickerBook?

        var selectedNoteCount: Int { selectedNotes.count }
    }

    var books: [Book]
    var query = ""
    var isCommitting = false
    var progressText = ""
    var errorMessage: String?
    var didCommit = false
    private let repository: any NoteImportRepositoryProtocol
    private var task: Task<Void, Never>?

    init(books: [NoteImportDraftBook], repository: any NoteImportRepositoryProtocol) {
        self.repository = repository
        self.books = books.map {
            Book(draft: $0, isSelected: books.count == 1, selectedNotes: books.count == 1 ? Set($0.notes.indices) : [])
        }
    }

    var visibleBooks: [Book] {
        guard !query.isEmpty else { return books }
        return books.filter { $0.draft.name.localizedCaseInsensitiveContains(query) || $0.draft.author.localizedCaseInsensitiveContains(query) }
    }

    var selectedCount: Int { books.filter(\.isSelected).count }

    func prepareMatches() async {
        for index in books.indices where books[index].target == nil {
            if Task.isCancelled { return }
            books[index].target = try? await repository.matchLocalBook(for: books[index].draft)
        }
    }

    func toggle(_ id: UUID) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].isSelected.toggle()
        if books[index].isSelected, books[index].selectedNotes.isEmpty { books[index].selectedNotes = Set(books[index].draft.notes.indices) }
    }

    func selectAll(_ selected: Bool) {
        for index in books.indices {
            books[index].isSelected = selected
            books[index].selectedNotes = selected ? Set(books[index].draft.notes.indices) : []
        }
    }

    func update(_ book: Book) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
    }

    func map(_ id: UUID, target: BookPickerBook?) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].target = target
    }

    func commit() {
        let selected = books.filter(\.isSelected).map { book -> NoteImportCommitBook in
            var draft = book.draft
            draft.notes = draft.notes.enumerated().compactMap { book.selectedNotes.contains($0.offset) ? $0.element : nil }
            return NoteImportCommitBook(draft: draft, targetBookID: book.target?.id)
        }
        guard !selected.isEmpty else { errorMessage = "请先选择书籍"; return }
        isCommitting = true
        task = Task {
            do {
                try await repository.commitImport(books: selected) { [weak self] current, total in
                    self?.progressText = "正在导入（\(current)/\(total)）"
                }
                didCommit = true
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            isCommitting = false
        }
    }

    func cancel() { task?.cancel() }
}

struct UnifiedNoteImportPreviewView: View {
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @State private var model: UnifiedNoteImportPreviewModel
    @State private var contentBook: UnifiedNoteImportPreviewModel.Book?
    @State private var mappingBook: UnifiedNoteImportPreviewModel.Book?
    @State private var editingBook: UnifiedNoteImportPreviewModel.Book?
    @State private var editedTitle = ""
    @State private var editedAuthor = ""

    init(books: [NoteImportDraftBook], repository: any NoteImportRepositoryProtocol) {
        _model = State(initialValue: UnifiedNoteImportPreviewModel(books: books, repository: repository))
    }

    var body: some View {
        List {
            Section { HStack { Button("全选") { model.selectAll(true) }; Spacer(); Button("取消全选") { model.selectAll(false) } } }
            ForEach(model.visibleBooks) { book in
                Section {
                    importBookRow(book)
                    HStack {
                        Button(book.target == nil ? "映射已有书籍" : "更换映射") { mappingBook = book }
                        if book.target != nil { Spacer(); Button("清除映射", role: .destructive) { model.map(book.id, target: nil) } }
                    }
                }
            }
        }
        .searchable(text: $model.query, prompt: "搜索书名或作者")
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("导入预览")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button { model.commit() } label: {
                HStack { Spacer(); if model.isCommitting { ProgressView().controlSize(.small) }; Text(model.isCommitting ? model.progressText : "导入（\(model.selectedCount)/\(model.books.count)）"); Spacer() }
            }
            .buttonStyle(.borderedProminent).padding(Spacing.screenEdge).background(.ultraThinMaterial).disabled(model.isCommitting)
        }
        .task { await model.prepareMatches() }
        .onDisappear { model.cancel() }
        .onChange(of: model.didCommit) { _, value in
            if value {
                navigationCoordinator.dismissTask()
            }
        }
        .navigationDestination(isPresented: Binding(get: { contentBook != nil }, set: { if !$0 { contentBook = nil } })) {
            if let book = contentBook { UnifiedNoteImportContentView(book: binding(for: book.id)) }
        }
        .sheet(item: $mappingBook) { book in
            BookPickerView(configuration: .init(title: "映射到已有书籍", scope: .local, selectionMode: .single, defaultQuery: book.draft.name)) { result in
                if case .single(.local(let selected)) = result { model.map(book.id, target: selected) }
                mappingBook = nil
            }
        }
        .xmSystemAlert(
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            descriptor: model.errorMessage.map { message in
                .init(
                    title: "无法导入",
                    message: message,
                    actions: [.init(title: "知道了") { model.errorMessage = nil }]
                )
            }
        )
        .xmSystemAlert(item: $editingBook) { book in
            .init(
                title: "编辑新书资料",
                actions: [
                    .init(title: "取消", role: .cancel) {},
                    .init(
                        title: "保存",
                        isEnabled: !editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        var updated = book
                        let title = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.draft.name = title
                        updated.draft.rawName = title
                        updated.draft.author = editedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.update(updated)
                    }
                ],
                textFields: [
                    .init(text: $editedTitle, placeholder: "书名"),
                    .init(text: $editedAuthor, placeholder: "作者")
                ]
            )
        }
    }

    /// 渲染同时承载选择按钮、内容预览点击与长按编辑的复合导入行。
    private func importBookRow(_ book: UnifiedNoteImportPreviewModel.Book) -> some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Button {
                model.toggle(book.id)
            } label: {
                XMSelectionIndicator(
                    style: .checkbox,
                    isSelected: book.isSelected,
                    font: AppTypography.title2,
                    showsUnselectedBase: true
                )
                .frame(
                    width: InteractionMetrics.minimumTouchTarget,
                    height: InteractionMetrics.minimumTouchTarget
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(book.isSelected ? "取消选择《\(book.draft.name)》" : "选择《\(book.draft.name)》")
            .accessibilityAddTraits(book.isSelected ? .isSelected : [])

            XMBookCover.fixedWidth(
                48,
                urlString: book.draft.cover,
                cornerRadius: CornerRadius.inlaySmall,
                placeholderIconSize: .small
            )

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(book.draft.name)
                    .font(AppTypography.headline)
                if !book.draft.author.isEmpty {
                    Text(book.draft.author)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                Text("\(book.draft.notes.count) 条书摘 · \(book.draft.reviews.count) 条书评")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                if let target = book.target {
                    Text("导入到：\(target.title)")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.selectionAccent)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openBookContentIfAvailable(book)
        }
        .onLongPressGesture {
            beginEditing(book)
        }
        .accessibilityActions {
            if !book.draft.notes.isEmpty || !book.draft.reviews.isEmpty {
                Button("预览导入内容") {
                    openBookContentIfAvailable(book)
                }
            }
            if book.target == nil {
                Button("编辑书籍信息") {
                    beginEditing(book)
                }
            }
        }
    }

    /// 打开至少含一条书摘或书评的导入内容预览。
    private func openBookContentIfAvailable(_ book: UnifiedNoteImportPreviewModel.Book) {
        guard !book.draft.notes.isEmpty || !book.draft.reviews.isEmpty else { return }
        contentBook = book
    }

    /// 进入未映射书籍的信息编辑态。
    private func beginEditing(_ book: UnifiedNoteImportPreviewModel.Book) {
        guard book.target == nil else { return }
        editedTitle = book.draft.name
        editedAuthor = book.draft.author
        editingBook = book
    }

    private func binding(for id: UUID) -> Binding<UnifiedNoteImportPreviewModel.Book> {
        Binding(get: { model.books.first(where: { $0.id == id })! }, set: model.update)
    }
}

private struct UnifiedNoteImportContentView: View {
    @Binding var book: UnifiedNoteImportPreviewModel.Book

    var body: some View {
        List {
            if !book.draft.notes.isEmpty {
                Section { HStack { Button("全选") { selectAll(true) }; Spacer(); Button("取消全选") { selectAll(false) } } } header: { Text("书摘") }
                ForEach(book.draft.notes.indices, id: \.self) { index in
                    HStack(alignment: .top) {
                        let isSelected = book.selectedNotes.contains(index)
                        Button { toggle(index) } label: {
                            XMSelectionIndicator(
                                style: .checkbox,
                                isSelected: isSelected,
                                font: AppTypography.title2,
                                showsUnselectedBase: true
                            )
                            .frame(
                                width: InteractionMetrics.minimumTouchTarget,
                                height: InteractionMetrics.minimumTouchTarget
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSelected ? "取消选择书摘" : "选择书摘")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        VStack(alignment: .leading) {
                            Text(book.draft.notes[index].content)
                            if !book.draft.notes[index].idea.isEmpty { Text(book.draft.notes[index].idea).font(AppTypography.caption).foregroundStyle(Color.textSecondary) }
                        }
                    }
                }
            }
            if !book.draft.reviews.isEmpty {
                Section("书评（随书导入）") { ForEach(book.draft.reviews.indices, id: \.self) { index in VStack(alignment: .leading) { if !book.draft.reviews[index].title.isEmpty { Text(book.draft.reviews[index].title).font(AppTypography.headline) }; Text(book.draft.reviews[index].content) } } }
            }
        }
        .navigationTitle(book.draft.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ index: Int) { if book.selectedNotes.contains(index) { book.selectedNotes.remove(index) } else { book.selectedNotes.insert(index) }; book.isSelected = !book.selectedNotes.isEmpty || !book.draft.reviews.isEmpty }
    private func selectAll(_ selected: Bool) { book.selectedNotes = selected ? Set(book.draft.notes.indices) : []; book.isSelected = selected || (!book.draft.reviews.isEmpty && book.isSelected) }
}
