/**
 * [INPUT]: 依赖共享导入会话、不可变书摘/书评与 XMJXImageWall
 * [OUTPUT]: 提供独立内容选择、图片浏览、来源位置时间和附件失败明细
 * [POS]: Views/Personal/DataImport 的内容子页面，选择仅回写单本编辑副本，顶层确认后合入会话
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 只读来源内容与可编辑选择分离；数组下标属于固定来源快照，不随筛选排序改变。
struct NoteImportContentPreviewView: View {
    @Bindable var model: NoteImportPreviewViewModel
    let bookID: UUID
    private var book: NoteImportPreviewBook? { model.books.first { $0.id == bookID } }

    var body: some View {
        Group {
            if let book {
                List {
                    if !book.source.notes.isEmpty {
                        Section("书摘") {
                            ForEach(Array(book.source.notes.enumerated()), id: \.offset) { index, note in
                                noteRow(note, index: index, book: book)
                            }
                        }
                    }
                    if !book.source.reviews.isEmpty {
                        Section("书评") {
                            ForEach(Array(book.source.reviews.enumerated()), id: \.offset) { index, review in
                                reviewRow(review, index: index, book: book)
                            }
                        }
                    }
                    if book.source.readingRecordCount > 0 {
                        Section("阅读记录") {
                            if book.source.hasPreviewReadingPosition {
                                Toggle("导入阅读位置", isOn: Binding(get: { book.includesReadingPosition }, set: { value in
                                    var updated = book; updated.includesReadingPosition = value; model.updateContents(updated)
                                }))
                                VStack(alignment: .leading, spacing: Spacing.cozy) {
                                    Text("阅读位置").font(AppTypography.bodyMedium)
                                    Text(positionValue(book.source.readPosition.formatted(.number.precision(.fractionLength(0...2))),
                                                       unit: book.source.currentPositionUnit))
                                        .font(AppTypography.subheadline)
                                    Text(date(book.source.bookmarkModifiedTime), format: .dateTime.year().month().day())
                                        .font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
                                }
                            }
                            ForEach(Array((book.source.preciseReadingDurations ?? []).enumerated()), id: \.offset) { _, record in
                                readingRecordRow(date: record.startTime, seconds: duration(record.startTime, record.endTime))
                            }
                            ForEach(Array((book.source.fuzzyReadingDurations ?? []).enumerated()), id: \.offset) { _, record in
                                readingRecordRow(date: record.date, seconds: record.durationSeconds)
                            }
                            ForEach(Array((book.source.wereadReadingDurations ?? []).enumerated()), id: \.offset) { _, record in
                                readingRecordRow(date: record.date, seconds: record.durationSeconds)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.surfaceSheet)
                .scrollBounceBehavior(.always)
                .disabled(model.isLocked || book.isCompleted)
                .navigationTitle(model.metadata(for: book).title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("全选笔记与位置") { selectAll(true) }
                            Button("取消笔记与位置") { selectAll(false) }
                        } label: { Text("选择") }
                        .xmToolbarNeutralTint()
                        .disabled(model.isLocked || book.isCompleted)
                    }
                }
            } else { XMContentStateView(role: .empty, title: "内容已失效") }
        }
    }

    /// 展示完整书摘和附属想法，附件异常保留在所属条目中。
    private func noteRow(_ note: NoteImportDraftNote, index: Int, book: NoteImportPreviewBook) -> some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                if !note.content.isEmpty { Text(note.content).font(AppTypography.body).foregroundStyle(Color.textPrimary) }
                if !note.idea.isEmpty { Text(note.idea).font(AppTypography.subheadline).foregroundStyle(Color.textSecondary) }
                if !note.attachments.isEmpty {
                    images(note.attachments.map(\.imageURL), prefix: "\(bookID)-note-\(index)")
                }
                if !note.failedAttachmentURLs.isEmpty {
                    DisclosureGroup("\(note.failedAttachmentURLs.count) 张图片未获取") {
                        ForEach(Array(note.failedAttachmentURLs.enumerated()), id: \.offset) { _, value in
                            Text(URL(string: value)?.lastPathComponent ?? "图片地址无效")
                                .font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
                        }
                        Button("取消选择这条书摘") { toggleNote(index, selected: false) }
                            .tint(Color.textPrimary)
                            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                    }
                    .font(AppTypography.footnote).tint(Color.textSecondary)
                }
                if !note.position.isEmpty { Text(position(note)).font(AppTypography.footnote).foregroundStyle(Color.textHint) }
                if note.isIncludeTime, note.createdTime > 0 {
                    Text(date(note.createdTime), format: .dateTime.year().month().day().hour().minute())
                        .font(AppTypography.footnote).foregroundStyle(Color.textHint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            selection(book.selectedNotes.contains(index), label: "书摘") {
                toggleNote(index, selected: !book.selectedNotes.contains(index))
            }
        }
        .padding(.vertical, Spacing.cozy)
        .listRowBackground(Color.surfaceSheet)
    }

    /// 书评提供独立选择，图片与来源日期保持原样。
    private func reviewRow(_ review: NoteImportDraftReview, index: Int, book: NoteImportPreviewBook) -> some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                if !review.title.isEmpty { Text(review.title).font(AppTypography.bodyMedium) }
                if !review.content.isEmpty { Text(review.content).font(AppTypography.body) }
                if !review.images.isEmpty { images(review.images.map(\.image), prefix: "\(bookID)-review-\(index)") }
                if review.createdTime > 0 {
                    Text(date(review.createdTime), format: .dateTime.year().month().day())
                        .font(AppTypography.footnote).foregroundStyle(Color.textHint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            selection(book.selectedReviews.contains(index), label: "书评") {
                var updated = book
                if updated.selectedReviews.contains(index) { updated.selectedReviews.remove(index) }
                else { updated.selectedReviews.insert(index) }
                model.updateContents(updated)
            }
        }
        .padding(.vertical, Spacing.cozy)
        .listRowBackground(Color.surfaceSheet)
    }

    /// 以来源条目及序号建立稳定图片身份，复用图片墙和全屏浏览。
    private func images(_ urls: [String], prefix: String) -> some View {
        XMJXImageWall(items: urls.enumerated().map { index, url in
            XMJXGalleryItem(id: "\(prefix)-\(index)", thumbnailURL: url, originalURL: url)
        })
    }

    /// 提供独立勾选按钮，避免内容阅读和选择争用整行点击。
    private func selection(_ selected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            XMSelectionIndicator(style: .checkbox, isSelected: selected, font: AppTypography.body, showsUnselectedBase: true)
                .frame(width: InteractionMetrics.minimumTouchTarget, height: InteractionMetrics.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "取消选择\(label)" : "选择\(label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 显示真实日期和时长，缺失时间不以当前日期补齐。
    private func readingRecordRow(date timestamp: Int64?, seconds: Int64?) -> some View {
        HStack(spacing: Spacing.base) {
            if let timestamp, timestamp > 0 { Text(date(timestamp), format: .dateTime.year().month().day()) }
            else { Text("未提供日期") }
            Spacer()
            if let seconds { Text("\(seconds / 60) 分钟").foregroundStyle(Color.textSecondary) }
        }
        .font(AppTypography.subheadline)
        .listRowBackground(Color.surfaceSheet)
    }

    /// 将来源毫秒时间转换为系统日期显示值。
    private func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
    /// 只从有效起止时间计算秒数，不为缺失时长造值。
    private func duration(_ start: Int64?, _ end: Int64?) -> Int64? {
        guard let start, let end, end >= start else { return nil }
        return (end - start) / 1_000
    }
    /// 按来源位置单位显示进度、位置或页码。
    private func position(_ note: NoteImportDraftNote) -> String {
        positionValue(note.position, unit: note.positionUnit)
    }
    /// 阅读位置和书摘位置共用来源单位，禁止把位置解释为阅读状态。
    private func positionValue(_ value: String, unit: Int64) -> String {
        switch unit {
        case 0: "\(value)%"
        case 1: "位置 \(value)"
        default: "第 \(value) 页"
        }
    }
    /// 只改变当前固定来源快照中指定书摘的选择。
    private func toggleNote(_ index: Int, selected: Bool) {
        guard var value = book else { return }
        if selected { value.selectedNotes.insert(index) } else { value.selectedNotes.remove(index) }
        model.updateContents(value)
    }
    /// 一次更新本书全部内容选择，不影响其他书籍。
    private func selectAll(_ selected: Bool) {
        guard var value = book else { return }
        value.selectedNotes = selected ? Set(value.source.notes.indices) : []
        value.selectedReviews = selected ? Set(value.source.reviews.indices) : []
        value.includesReadingPosition = selected
        model.updateContents(value)
    }
}

/// 逐书结果与剩余工作同屏呈现，关闭结果不会丢弃失败条目的草稿。
struct NoteImportResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: NoteImportPreviewViewModel
    let onFinish: () -> Void
    let onRetry: () -> Void

    var body: some View {
        XMSheetScaffold(title: "导入结果", onClose: { dismiss() }, confirmationAction: {
            if model.selectedCount == 0 { onFinish() } else { dismiss() }
        }) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("已完成 \(model.completedCount) 本").font(AppTypography.bodyMedium)
                if model.selectedCount > 0 {
                    Button("继续导入未完成内容") { dismiss(); onRetry() }
                        .font(AppTypography.body).tint(Color.textPrimary)
                        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                }
                ForEach(model.results) { result in
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Text(result.title).font(AppTypography.body)
                        Text("已完成").font(AppTypography.footnote)
                        if result.includesDuration {
                            Text("\(result.policy.summary)，现有 \(NoteImportDurationMerge.text(result.finalSeconds))")
                                .font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
                        }
                        Divider()
                    }
                }
                ForEach(model.pendingResultBooks) { book in
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Text(model.metadata(for: book).title).font(AppTypography.body)
                        Text(book.issue ?? "未完成").font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
                        Divider()
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }
}
