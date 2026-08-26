/**
 * [INPUT]: 依赖 Foundation，接收 Android `/send` 协议 JSON
 * [OUTPUT]: 对外提供 ApiNoteImportDTO 的同文案校验与 ApiImportBookPayload 转换
 * [POS]: Services 的 API 导入协议边界；HTTP 服务和测试共同调用，禁止 UI 自行解释 JSON
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct ApiNoteImportDTO: Decodable, Sendable {
    struct Entry: Decodable, Sendable { var page: Int?; var text: String?; var note: String?; var chapter: String?; var time: Int64? }
    struct Review: Decodable, Sendable { var title: String?; var content: String?; var time: Int64? }
    struct Chapter: Decodable, Sendable { var title: String?; var children: [Chapter]? }
    struct PreciseDuration: Decodable, Sendable { var startTime: Int64?; var endTime: Int64?; var position: Double? }
    struct FuzzyDuration: Decodable, Sendable { var date: Int64?; var durationSeconds: Int64?; var position: Double? }

    var title: String?
    var cover: String?
    var coverBase64: String?
    var author: String?
    var translator: String?
    var publisher: String?
    var publishDate: Int64?
    var isbn: String?
    var type: Int64?
    var locationUnit: Int64?
    var bookSummary: String?
    var authorIntro: String?
    var totalPageCount: Int64?
    var currentPage: Double?
    var rating: Double?
    var readingStatus: Int64?
    var readingStatusChangedDate: Int64?
    var group: String?
    var tags: [String]?
    var source: String?
    var purchaseDate: Int64?
    var purchasePrice: Double?
    var entries: [Entry]?
    var reviews: [Review]?
    var chapters: [Chapter]?
    var preciseReadingDurations: [PreciseDuration]?
    var fuzzyReadingDurations: [FuzzyDuration]?

    func validatedPayload(now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) throws -> ApiImportBookPayload {
        let bookTitle = title ?? ""
        guard !bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw validation("书籍名称（title）是必填项，不能为空") }
        if Self.looksLikeBase64Image(cover) { throw validation("书籍封面的 Base64 内容请通过 coverBase64 字段传入") }
        if let isbn, !isbn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Self.isValidISBN(isbn) { throw validation("isbn格式不正确") }
        if let publishDate, publishDate < 0 { throw validation("出版日期时间戳（publishDate）的值必须大于0") }
        guard let type else { throw validation("书籍类型（type）是必填项，不能为空") }
        guard type == 0 || type == 1 else { throw validation("书籍类型（type）不正确") }
        guard let locationUnit else { throw validation("位置单位（positionUnit）是必填项，不能为空") }
        if type == 0, locationUnit != 2 { throw validation("当书籍类型（type）是纸质书时，仅支持以页码（2）作为该书的位置单位") }
        if type == 1, locationUnit != 0, locationUnit != 1 { throw validation("当书籍类型（type）是电子书时，仅支持以进度（0）、位置（1）作为该书的位置单位") }
        let normalizedTotal = locationUnit == 0 ? nil : totalPageCount
        if currentPage != nil, normalizedTotal == nil, locationUnit != 0 { throw validation("书籍总页码（totalPageCount）不能为空") }
        if let currentPage, locationUnit == 0, !(0...100).contains(currentPage) { throw validation(normalizedTotal == nil ? "填写有误，阅读进度的取值范围为[0, 100]" : "阅读进度（currentPage）的取值范围为[0, 100]") }
        if let currentPage, let normalizedTotal, locationUnit != 0 {
            if currentPage < 0 { throw validation("阅读进度（currentPage）的数值必须要大于0") }
            if normalizedTotal < 0 { throw validation("书籍总页码（totalPageCount）的数值必须要大于0") }
            if currentPage > Double(normalizedTotal) { throw validation("填写有误，阅读进度（currentPage）的取值不能大于总页码") }
        }
        if let rating, !(0...5).contains(rating) { throw validation("评分（rating）的取值范围为[0,5]") }
        if let readingStatus, !(0...5).contains(readingStatus) { throw validation("阅读状态（readStatus）的取值范围为[0,5]") }
        if let readingStatusChangedDate, readingStatusChangedDate < 0 { throw validation("阅读状态修改时的时间戳（readingStatusChangedData）的值必须大于0") }
        if let purchasePrice, purchasePrice < 0 { throw validation("书籍购买价格（purchasePrice）不能小于0") }
        if let purchaseDate, purchaseDate < 0 { throw validation("书籍购买日期时间戳（purchaseDate）不能小于0") }
        try validateDurations(now: now)
        try validateChapters(chapters, depth: 1)

        var payload = ApiImportBookPayload()
        payload.name = bookTitle
        payload.rawName = bookTitle
        payload.cover = cover?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        payload.apiImportCoverBase64 = coverBase64?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        payload.author = author ?? ""
        payload.authorIntro = authorIntro ?? ""
        payload.translator = translator ?? ""
        payload.summary = bookSummary ?? ""
        payload.isbn = isbn ?? ""
        payload.press = publisher ?? ""
        payload.pubDate = Self.dateString(publishDate)
        payload.type = type
        payload.positionUnit = locationUnit
        payload.readPosition = currentPage ?? 0
        if locationUnit == 2 { payload.totalPagination = normalizedTotal ?? 0 }
        if locationUnit == 1 { payload.totalPosition = normalizedTotal ?? 0 }
        payload.score = Int64(((rating ?? 0) * 10).rounded(.towardZero))
        payload.readStatusId = readingStatus == nil || readingStatus == 0 ? 1 : readingStatus!
        payload.readStatusChangedDate = Self.milliseconds(readingStatusChangedDate ?? 0)
        if let group, !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payload.group = ApiImportGroupPayload(name: group) }
        payload.tags = (tags ?? []).map { ApiImportTagPayload(name: $0) }
        payload.sourceName = source ?? ""
        payload.source = Int64(Self.sourceNames.firstIndex(of: payload.sourceName).map { $0 + 1 } ?? 1)
        payload.purchaseDate = Self.milliseconds(purchaseDate ?? 0)
        payload.price = purchasePrice ?? 0
        payload.noteList = (entries ?? []).compactMap { entry in
            guard entry.text != nil || entry.note != nil else { return nil }
            var chapter = ApiImportChapterPayload(); chapter.title = entry.chapter ?? ""
            return ApiImportNotePayload(
                content: entry.text ?? "",
                idea: entry.note ?? "",
                position: entry.page.map(String.init) ?? "",
                chapter: chapter,
                createdDateTime: Self.milliseconds(entry.time ?? 0)
            )
        }
        payload.apiImportReviews = (reviews ?? []).compactMap { review in
            let title = review.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let content = review.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty || !content.isEmpty else { return nil }
            return ApiImportReviewPayload(title: title, content: content, createdDateTime: Self.milliseconds(review.time ?? 0))
        }
        payload.apiImportChapterList = Self.chapterPayloads(chapters ?? [], path: [])
        payload.preciseReadingDurations = preciseReadingDurations?.map { .init(startTime: $0.startTime.map(Self.milliseconds), endTime: $0.endTime.map(Self.milliseconds), position: $0.position) }
        payload.fuzzyReadingDurations = fuzzyReadingDurations?.map { .init(date: $0.date.map(Self.milliseconds), durationSeconds: $0.durationSeconds, position: $0.position) }
        return payload
    }
}

private extension ApiNoteImportDTO {
    nonisolated struct ValidationError: LocalizedError, Sendable { let message: String; var errorDescription: String? { message } }
    nonisolated func validation(_ message: String) -> ValidationError { ValidationError(message: message) }

    nonisolated func validateDurations(now: Int64) throws {
        for duration in preciseReadingDurations ?? [] {
            guard let start = duration.startTime else { throw validation("精确阅读时长的开始时间（startTime）不能为空") }
            guard let end = duration.endTime else { throw validation("精确阅读时长的结束时间（endTime）不能为空") }
            guard end > start else { throw validation("精确阅读时长的结束时间（endTime）要大于开始时间（startTime）") }
            guard Self.milliseconds(end) <= now else { throw validation("精确阅读时长的结束时间（endTime）不能大于当前真实世界的时间") }
            if let position = duration.position, position < 0 { throw validation("本次记录的阅读位置（position）不能小于 0") }
        }
        for duration in fuzzyReadingDurations ?? [] {
            guard let date = duration.date else { throw validation("模糊阅读时长的日期（date）不能为空") }
            guard Self.milliseconds(date) <= now else { throw validation("模糊阅读时长的阅读日期（date）不能大于当前真实世界的时间") }
            guard let seconds = duration.durationSeconds else { throw validation("模糊阅读时长的时长（durationSeconds）不能为空") }
            guard seconds > 0 else { throw validation("模糊阅读时长的时长（durationSeconds）要多于 0 秒") }
            if let position = duration.position, position < 0 { throw validation("本次记录的阅读位置（position）不能小于 0") }
        }
    }

    nonisolated func validateChapters(_ chapters: [Chapter]?, depth: Int) throws {
        guard let chapters, !chapters.isEmpty else { return }
        guard depth <= 5 else { throw validation("章节层级不能超过 5 层") }
        for chapter in chapters {
            guard let title = chapter.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw validation("章节标题不能为空") }
            try validateChapters(chapter.children, depth: depth + 1)
        }
    }

    nonisolated static func chapterPayloads(_ chapters: [Chapter], path: [String]) -> [ApiImportChapterPayload] {
        chapters.enumerated().compactMap { offset, chapter in
            guard let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let currentPath = path + [title]
            var payload = ApiImportChapterPayload(); payload.title = title; payload.order = Int64(offset + 1); payload.isImport = 1; payload.level = Int64(currentPath.count); payload.sourceType = 2; payload.pathTitles = currentPath; payload.sourcePath = currentPath.joined(separator: "$"); payload.children = chapterPayloads(chapter.children ?? [], path: currentPath); return payload
        }
    }

    nonisolated static func milliseconds(_ value: Int64) -> Int64 { String(value).count == 10 ? value * 1_000 : value }
    nonisolated static func dateString(_ value: Int64?) -> String {
        guard let value, value != 0 else { return "" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds(value)) / 1_000))
    }
    nonisolated static func looksLikeBase64Image(_ value: String?) -> Bool {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.lowercased().hasPrefix("data:image") { return true }
        if value.contains("://") || value.count < 64 { return false }
        guard value.range(of: "^[A-Za-z0-9+/=\\r\\n]+$", options: .regularExpression) != nil else { return false }
        return ["iVBOR", "/9j/", "R0lGOD", "UklGR", "Qk"].contains { value.hasPrefix($0) }
    }
    nonisolated static func isValidISBN(_ raw: String) -> Bool {
        let value = raw.uppercased().filter { $0.isNumber || $0 == "X" }
        if value.count == 10 {
            let chars = Array(value); var sum = 0
            for index in 0..<9 { guard let digit = chars[index].wholeNumberValue else { return false }; sum += digit * (10 - index) }
            let check = chars[9] == "X" ? 10 : chars[9].wholeNumberValue ?? -1
            return (sum + check) % 11 == 0
        }
        if value.count == 13 {
            let digits = value.compactMap(\.wholeNumberValue); guard digits.count == 13 else { return false }
            let sum = digits.prefix(12).enumerated().reduce(0) { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 1 : 3) }
            return (10 - sum % 10) % 10 == digits[12]
        }
        return false
    }
    nonisolated static let sourceNames = ["未知", "Kindle阅读器", "Kindle App", "微信读书", "Apple Books", "静读天下", "多看阅读", "掌阅", "豆瓣阅读", "掌阅精选", "京东读书", "文石阅读器", "当当云阅读", "KOReader", "网易蜗牛", "豆瓣阅读(App)", "阅读", "Neat Reader", "汉王阅读器", "番茄小说", "滴墨书摘", "三联生活周刊", "Koodo Reader", "iReader", "得到", "Reeden", "Readingo"]
}
