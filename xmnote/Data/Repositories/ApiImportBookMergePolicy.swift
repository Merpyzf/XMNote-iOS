/**
 * [INPUT]: 依赖 Foundation，接收 API 导入阶段临时书籍/书摘/书评/阅读时长载荷
 * [OUTPUT]: 对外提供 ApiImportBookMergePolicy 与内部导入载荷模型，复刻 Android API 导入会话内合并规则
 * [POS]: Data 层导入策略工具，不接入 UI，不修改 Repository 协议，供后续 API 导入入口复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// API 导入会话内的书籍合并策略，保持与 Android `ApiImportBookMergeHelper` 一致的去重和择优规则。
nonisolated enum ApiImportBookMergePolicy {
    /// 将一本导入书加入会话列表；若命中同一本书，则把 incoming 合并进首个已存在对象。
    @discardableResult
    nonisolated static func addOrMergeBook(
        _ books: inout [ApiImportBookPayload],
        incoming: ApiImportBookPayload
    ) -> ApiImportBookPayload {
        let incomingKey = buildBookDedupKey(incoming)
        guard let existedIndex = books.firstIndex(where: { buildBookDedupKey($0) == incomingKey }) else {
            books.append(incoming)
            return incoming
        }

        mergeBook(&books[existedIndex], incoming: incoming)
        return books[existedIndex]
    }

    /// 合并一批导入书，保留首次出现对象并吸收后续重复项。
    nonisolated static func mergeBooks(_ books: [ApiImportBookPayload]) -> [ApiImportBookPayload] {
        var mergedBooks: [ApiImportBookPayload] = []
        for book in books {
            addOrMergeBook(&mergedBooks, incoming: book)
        }
        return mergedBooks
    }

    /// 按 Android API 导入展示顺序排序：书摘升序，书籍按最新导入内容时间降序。
    nonisolated static func sortForImport(_ books: inout [ApiImportBookPayload]) {
        for index in books.indices {
            books[index].noteList.sort { lhs, rhs in
                lhs.createdDateTime < rhs.createdDateTime
            }
        }
        books.sort { lhs, rhs in
            lhs.latestImportContentDateTime > rhs.latestImportContentDateTime
        }
    }

    /// 生成 API 导入书籍去重 key；ISBN 优先，否则退回元数据组合。
    nonisolated static func buildBookDedupKey(_ book: ApiImportBookPayload) -> String {
        let normalizedIsbn = normalizeBookField(book.isbn)
        if !normalizedIsbn.isEmpty {
            return "isbn:\(normalizedIsbn)"
        }

        return [
            normalizeBookField(book.name),
            normalizeBookField(book.author),
            normalizeBookField(book.translator),
            normalizeBookField(book.press),
            String(book.type),
            String(book.positionUnit),
            normalizeBookField(book.sourceName)
        ].joined(separator: "\u{0}").withPrefix("meta:")
    }
}

/// API 导入阶段的临时书籍载荷；字段按 Android Book 合并规则保留，不代表持久化 Record。
nonisolated struct ApiImportBookPayload: Sendable, Equatable {
    var isChecked = false
    var name = ""
    var rawName = ""
    var cover = ""
    var author = ""
    var authorIntro = ""
    var translator = ""
    var summary = ""
    var isbn = ""
    var press = ""
    var pubDate = ""
    var readPosition: Double = 0
    var totalPosition: Int64 = 0
    var totalPagination: Int64 = 0
    var type: Int64 = 0
    var positionUnit: Int64 = 0
    var source: Int64 = 0
    var sourceName = ""
    var purchaseDate: Int64 = 0
    var price: Double = 0
    var readStatusId: Int64 = 1
    var readStatusChangedDate: Int64 = 0
    var score: Int64 = 0
    var createdDateTime: Int64 = 0
    var wereadUpdateTime: Int64 = 0
    var wordCount: Int64?
    var group: ApiImportGroupPayload?
    var tags: [ApiImportTagPayload] = []
    var noteList: [ApiImportNotePayload] = []
    var apiImportReviews: [ApiImportReviewPayload] = []
    var preciseReadingDurations: [ApiImportPreciseReadingDurationPayload]?
    var fuzzyReadingDurations: [ApiImportFuzzyReadingDurationPayload]?
    var apiImportCoverBase64 = ""

    /// 读取本书在导入内容中的最新活动时间，用于重复书状态择优和列表排序。
    nonisolated var latestImportContentDateTime: Int64 {
        [
            noteList.map(\.createdDateTime).max() ?? 0,
            apiImportReviews.map(\.createdDateTime).max() ?? 0,
            preciseReadingDurations?.compactMap(\.endTime).max() ?? 0,
            fuzzyReadingDurations?.compactMap(\.date).max() ?? 0,
            wereadUpdateTime
        ].max() ?? 0
    }
}

/// API 导入阶段的临时分组载荷。
nonisolated struct ApiImportGroupPayload: Sendable, Equatable {
    var name = ""
}

/// API 导入阶段的临时标签载荷。
nonisolated struct ApiImportTagPayload: Sendable, Equatable {
    var name = ""
}

/// API 导入阶段的临时章节载荷。
nonisolated struct ApiImportChapterPayload: Sendable, Equatable {
    var id: Int64 = 0
    var bookId: Int64 = 0
    var parentChapterId: Int64 = 0
    var title = ""
    var remark = ""
    var order: Int64 = 0
    var noteCount: Int64 = 0
    var uid = ""
    var currentItemType: Int64 = 0
    var isChecked = false
    var isImport: Int64 = 0
}

/// API 导入阶段的临时书摘载荷。
nonisolated struct ApiImportNotePayload: Sendable, Equatable {
    var isChecked = false
    var content = ""
    var idea = ""
    var position = ""
    var chapter = ApiImportChapterPayload()
    var createdDateTime: Int64 = 0
    var attachImages: [ApiImportAttachImagePayload] = []
}

/// API 导入阶段的临时附图载荷。
nonisolated struct ApiImportAttachImagePayload: Sendable, Equatable {
    var imageURL = ""
}

/// API 导入阶段的临时书评载荷。
nonisolated struct ApiImportReviewPayload: Sendable, Equatable {
    var title = ""
    var content = ""
    var createdDateTime: Int64 = 0
}

/// API 导入阶段的精确阅读时长载荷。
nonisolated struct ApiImportPreciseReadingDurationPayload: Sendable, Equatable {
    var startTime: Int64?
    var endTime: Int64?
    var position: Double?
}

/// API 导入阶段的模糊阅读时长载荷。
nonisolated struct ApiImportFuzzyReadingDurationPayload: Sendable, Equatable {
    var date: Int64?
    var durationSeconds: Int64?
    var position: Double?
}

private extension ApiImportBookMergePolicy {
    nonisolated static func mergeBook(_ target: inout ApiImportBookPayload, incoming: ApiImportBookPayload) {
        let targetLatestContentTime = target.latestImportContentDateTime
        let incomingLatestContentTime = incoming.latestImportContentDateTime
        let preferIncomingState = incomingLatestContentTime >= targetLatestContentTime

        target.isChecked = target.isChecked || incoming.isChecked
        target.name = preferNonBlank(target.name, incoming.name)
        target.rawName = preferNonBlank(target.rawName, incoming.rawName)
        target.author = preferNonBlank(target.author, incoming.author)
        target.authorIntro = preferNonBlank(target.authorIntro, incoming.authorIntro)
        target.translator = preferNonBlank(target.translator, incoming.translator)
        target.summary = preferNonBlank(target.summary, incoming.summary)
        target.isbn = preferNonBlank(target.isbn, incoming.isbn)
        target.press = preferNonBlank(target.press, incoming.press)
        target.pubDate = preferNonBlank(target.pubDate, incoming.pubDate)

        let shouldSyncSource = target.sourceName.isBlank && !incoming.sourceName.isBlank
        if shouldSyncSource {
            target.source = incoming.source
        }
        target.sourceName = preferNonBlank(target.sourceName, incoming.sourceName)

        if target.group == nil, incoming.group != nil {
            target.group = incoming.group
        } else if let targetGroup = target.group,
                  let incomingGroup = incoming.group,
                  targetGroup.name.isBlank {
            target.group = incomingGroup
        }

        if shouldReplaceCover(target: target, incoming: incoming) {
            target.cover = incoming.cover
            target.apiImportCoverBase64 = incoming.apiImportCoverBase64
        }

        target.tags = mergeTags(target.tags, incoming.tags)
        target.noteList = mergeNotes(target.noteList, incoming.noteList)
        target.apiImportReviews = mergeReviews(target.apiImportReviews, incoming.apiImportReviews)
        target.preciseReadingDurations = mergePreciseDurations(
            target.preciseReadingDurations,
            incoming.preciseReadingDurations
        )
        target.fuzzyReadingDurations = mergeFuzzyDurations(
            target.fuzzyReadingDurations,
            incoming.fuzzyReadingDurations
        )

        if preferIncomingState {
            target.readPosition = preferLatestDouble(target.readPosition, incoming.readPosition)
            target.totalPosition = preferLatestInt(target.totalPosition, incoming.totalPosition)
            target.totalPagination = preferLatestInt(target.totalPagination, incoming.totalPagination)
            if incoming.readStatusChangedDate != 0 || target.readStatusId == 1 {
                target.readStatusId = incoming.readStatusId
            }
            target.readStatusChangedDate = preferLatestInt(
                target.readStatusChangedDate,
                incoming.readStatusChangedDate
            )
            target.score = preferLatestInt(target.score, incoming.score)
            target.wordCount = incoming.wordCount ?? target.wordCount
            target.wereadUpdateTime = preferLatestInt(target.wereadUpdateTime, incoming.wereadUpdateTime)
            target.purchaseDate = preferLatestInt(target.purchaseDate, incoming.purchaseDate)
            target.price = preferLatestDouble(target.price, incoming.price)
            target.createdDateTime = preferLatestInt(target.createdDateTime, incoming.createdDateTime)
        } else {
            if target.readPosition == 0 {
                target.readPosition = incoming.readPosition
            }
            if target.totalPosition == 0 {
                target.totalPosition = incoming.totalPosition
            }
            if target.totalPagination == 0 {
                target.totalPagination = incoming.totalPagination
            }
            target.readStatusChangedDate = fillIfMissing(target.readStatusChangedDate, incoming.readStatusChangedDate)
            target.wordCount = target.wordCount ?? incoming.wordCount
            target.wereadUpdateTime = fillIfMissing(target.wereadUpdateTime, incoming.wereadUpdateTime)
            target.purchaseDate = fillIfMissing(target.purchaseDate, incoming.purchaseDate)
            target.price = fillIfMissing(target.price, incoming.price)
            target.createdDateTime = fillIfMissing(target.createdDateTime, incoming.createdDateTime)
        }
    }

    nonisolated static func shouldReplaceCover(target: ApiImportBookPayload, incoming: ApiImportBookPayload) -> Bool {
        let targetPriority = coverPriority(target)
        let incomingPriority = coverPriority(incoming)
        guard incomingPriority != 0 else { return false }
        return incomingPriority > targetPriority
            || (incomingPriority == targetPriority && target.cover.isBlank && !incoming.cover.isBlank)
    }

    nonisolated static func coverPriority(_ book: ApiImportBookPayload) -> Int {
        if !book.apiImportCoverBase64.isBlank {
            return 3
        }
        if book.cover.lowercased().hasPrefix("data:image") {
            return 2
        }
        if !book.cover.isBlank {
            return 1
        }
        return 0
    }

    nonisolated static func mergeTags(
        _ targetTags: [ApiImportTagPayload],
        _ incomingTags: [ApiImportTagPayload]
    ) -> [ApiImportTagPayload] {
        var mergedTags = targetTags
        var existingKeys = Set(mergedTags.map { normalizeBookField($0.name) })
        for tag in incomingTags {
            let tagKey = normalizeBookField(tag.name)
            guard !tagKey.isEmpty, !existingKeys.contains(tagKey) else { continue }
            mergedTags.append(tag)
            existingKeys.insert(tagKey)
        }
        return mergedTags
    }

    nonisolated static func mergeNotes(
        _ targetNotes: [ApiImportNotePayload],
        _ incomingNotes: [ApiImportNotePayload]
    ) -> [ApiImportNotePayload] {
        var mergedNotes = targetNotes
        var noteIndexMap: [String: Int] = [:]
        for (index, note) in mergedNotes.enumerated() {
            let key = buildNoteDedupKey(note)
            if !key.isEmpty {
                noteIndexMap[key] = index
            }
        }

        for incomingNote in incomingNotes {
            let noteKey = buildNoteDedupKey(incomingNote)
            guard !noteKey.isEmpty else {
                mergedNotes.append(incomingNote)
                continue
            }

            if let existedIndex = noteIndexMap[noteKey] {
                mergeNote(&mergedNotes[existedIndex], incoming: incomingNote)
            } else {
                mergedNotes.append(incomingNote)
                noteIndexMap[noteKey] = mergedNotes.indices.last
            }
        }
        return mergedNotes
    }

    nonisolated static func mergeNote(_ target: inout ApiImportNotePayload, incoming: ApiImportNotePayload) {
        target.isChecked = target.isChecked || incoming.isChecked
        target.content = preferNonBlank(target.content, incoming.content)
        target.idea = preferNonBlank(target.idea, incoming.idea)
        target.position = preferNonBlank(target.position, incoming.position)
        if target.chapter.title.isBlank, !incoming.chapter.title.isBlank {
            target.chapter = incoming.chapter
        }
        if target.createdDateTime == 0, incoming.createdDateTime != 0 {
            target.createdDateTime = incoming.createdDateTime
        }
        for image in incoming.attachImages where !target.attachImages.contains(where: { $0.imageURL == image.imageURL }) {
            target.attachImages.append(image)
        }
    }

    nonisolated static func mergeReviews(
        _ targetReviews: [ApiImportReviewPayload],
        _ incomingReviews: [ApiImportReviewPayload]
    ) -> [ApiImportReviewPayload] {
        var mergedReviews = targetReviews
        var reviewIndexMap: [String: Int] = [:]
        for (index, review) in mergedReviews.enumerated() {
            let key = buildReviewDedupKey(review)
            if !key.isEmpty {
                reviewIndexMap[key] = index
            }
        }

        for incomingReview in incomingReviews {
            let reviewKey = buildReviewDedupKey(incomingReview)
            guard !reviewKey.isEmpty else {
                mergedReviews.append(incomingReview)
                continue
            }

            if let existedIndex = reviewIndexMap[reviewKey] {
                mergeReview(&mergedReviews[existedIndex], incoming: incomingReview)
            } else {
                mergedReviews.append(incomingReview)
                reviewIndexMap[reviewKey] = mergedReviews.indices.last
            }
        }
        return mergedReviews
    }

    nonisolated static func mergeReview(_ target: inout ApiImportReviewPayload, incoming: ApiImportReviewPayload) {
        target.title = preferNonBlank(target.title, incoming.title)
        target.content = preferNonBlank(target.content, incoming.content)
        if target.createdDateTime == 0, incoming.createdDateTime != 0 {
            target.createdDateTime = incoming.createdDateTime
        }
    }

    nonisolated static func mergePreciseDurations(
        _ targetDurations: [ApiImportPreciseReadingDurationPayload]?,
        _ incomingDurations: [ApiImportPreciseReadingDurationPayload]?
    ) -> [ApiImportPreciseReadingDurationPayload]? {
        if targetDurations == nil, incomingDurations == nil {
            return nil
        }

        var mergedDurations = targetDurations ?? []
        var durationIndexMap: [String: Int] = [:]
        for (index, duration) in mergedDurations.enumerated() {
            if let key = buildPreciseDurationKey(duration) {
                durationIndexMap[key] = index
            }
        }

        for incomingDuration in incomingDurations ?? [] {
            guard let durationKey = buildPreciseDurationKey(incomingDuration) else {
                mergedDurations.append(incomingDuration)
                continue
            }
            if let existedIndex = durationIndexMap[durationKey] {
                if mergedDurations[existedIndex].position == nil, incomingDuration.position != nil {
                    mergedDurations[existedIndex] = incomingDuration
                }
            } else {
                mergedDurations.append(incomingDuration)
                durationIndexMap[durationKey] = mergedDurations.indices.last
            }
        }
        return mergedDurations
    }

    nonisolated static func mergeFuzzyDurations(
        _ targetDurations: [ApiImportFuzzyReadingDurationPayload]?,
        _ incomingDurations: [ApiImportFuzzyReadingDurationPayload]?
    ) -> [ApiImportFuzzyReadingDurationPayload]? {
        if targetDurations == nil, incomingDurations == nil {
            return nil
        }

        var mergedDurations = targetDurations ?? []
        var durationIndexMap: [Int64: Int] = [:]
        for (index, duration) in mergedDurations.enumerated() {
            if let key = buildFuzzyDurationKey(duration) {
                durationIndexMap[key] = index
            }
        }

        for incomingDuration in incomingDurations ?? [] {
            guard let durationKey = buildFuzzyDurationKey(incomingDuration) else {
                mergedDurations.append(incomingDuration)
                continue
            }
            if let existedIndex = durationIndexMap[durationKey] {
                let targetDuration = mergedDurations[existedIndex]
                mergedDurations[existedIndex] = ApiImportFuzzyReadingDurationPayload(
                    date: targetDuration.date ?? incomingDuration.date,
                    durationSeconds: max(targetDuration.durationSeconds ?? 0, incomingDuration.durationSeconds ?? 0),
                    position: incomingDuration.position ?? targetDuration.position
                )
            } else {
                mergedDurations.append(incomingDuration)
                durationIndexMap[durationKey] = mergedDurations.indices.last
            }
        }
        return mergedDurations
    }

    nonisolated static func buildNoteDedupKey(_ note: ApiImportNotePayload) -> String {
        let normalizedContent = normalizeText(note.content)
        let normalizedIdea = normalizeText(note.idea)
        guard !normalizedContent.isEmpty || !normalizedIdea.isEmpty else { return "" }
        return "\(normalizedContent)\u{0}\(normalizedIdea)"
    }

    nonisolated static func buildReviewDedupKey(_ review: ApiImportReviewPayload) -> String {
        let normalizedTitle = normalizeText(review.title)
        let normalizedContent = normalizeText(clearHTML(review.content))
        guard !normalizedTitle.isEmpty || !normalizedContent.isEmpty else { return "" }
        return "\(normalizedTitle)\u{0}\(normalizedContent)"
    }

    nonisolated static func buildPreciseDurationKey(_ duration: ApiImportPreciseReadingDurationPayload) -> String? {
        guard let startTime = duration.startTime,
              let endTime = duration.endTime else {
            return nil
        }
        return "\(startTime)\u{0}\(endTime)"
    }

    nonisolated static func buildFuzzyDurationKey(_ duration: ApiImportFuzzyReadingDurationPayload) -> Int64? {
        guard let date = duration.date else { return nil }
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(date) / 1000))
        return Int64(dayStart.timeIntervalSince1970 * 1000)
    }

    nonisolated static func normalizeBookField(_ value: String) -> String {
        normalizeText(value)
    }

    nonisolated static func normalizeText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    nonisolated static func clearHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    nonisolated static func preferNonBlank(_ current: String, _ incoming: String) -> String {
        current.isBlank && !incoming.isBlank ? incoming : current
    }

    nonisolated static func preferLatestInt(_ current: Int64, _ incoming: Int64) -> Int64 {
        incoming != 0 || current == 0 ? incoming : current
    }

    nonisolated static func preferLatestDouble(_ current: Double, _ incoming: Double) -> Double {
        incoming != 0 || current == 0 ? incoming : current
    }

    nonisolated static func fillIfMissing(_ current: Int64, _ incoming: Int64) -> Int64 {
        current == 0 ? incoming : current
    }

    nonisolated static func fillIfMissing(_ current: Double, _ incoming: Double) -> Double {
        current == 0 ? incoming : current
    }
}

private extension String {
    nonisolated var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated func withPrefix(_ prefix: String) -> String {
        prefix + self
    }
}
