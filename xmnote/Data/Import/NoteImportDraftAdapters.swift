/**
 * [INPUT]: 依赖 NoteImportModels、WereadImportModels 与 ApiImportBookMergePolicy 载荷
 * [OUTPUT]: 对外提供微信读书和 API 导入结果到统一 NoteImportDraftBook 的无损 Adapter
 * [POS]: Data/Import 的来源收敛层，使所有预览与提交只消费一套 Draft
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated extension WereadImportBook {
    /// 将已抓取微信读书数据接入统一预览模型，不改变原有选择状态或远端排序。
    func asNoteImportDraft() -> NoteImportDraftBook {
        var draft = NoteImportDraftBook()
        draft.name = title
        draft.rawName = rawTitle
        draft.author = author
        draft.translator = translator
        draft.press = press
        draft.isbn = isbn
        draft.summary = summary
        draft.pubDate = publicationDate
        draft.cover = coverURL
        draft.type = 1
        draft.source = 4
        draft.positionUnit = 1
        draft.currentPositionUnit = 1
        draft.wordCount = wordCount
        draft.readStatusID = readStatusID
        draft.readStatusChangedDate = readStatusChangedAt
        draft.wereadBookID = wereadBookID
        draft.wereadUpdateTime = wereadUpdatedAt
        draft.chapters = chapters.map(NoteImportDraftChapter.init)
        draft.notes = notes.map {
            NoteImportDraftNote(
                content: $0.content,
                idea: $0.idea,
                positionUnit: 1,
                createdTime: $0.createdAt,
                isIncludeTime: true,
                wereadRange: $0.range,
                wereadChapterUID: $0.chapterUID,
                chapter: nil
            )
        }
        draft.reviews = reviews.map {
            NoteImportDraftReview(title: $0.title, content: $0.content, createdTime: $0.createdAt)
        }
        draft.fuzzyReadingDurations = readingDays.map {
            NoteImportFuzzyReadingDuration(date: $0.date, durationSeconds: $0.seconds, position: nil)
        }
        return draft
    }
}

nonisolated extension NoteImportDraftChapter {
    init(_ chapter: WereadImportChapter) {
        title = chapter.title
        level = chapter.level
        order = chapter.order
        sourceType = 1
        sourceUID = String(chapter.uid)
        sourceAnchor = chapter.sourceAnchor
        sourceOrder = chapter.order
        sourcePath = chapter.sourcePath
        children = chapter.children.map(Self.init)
    }
}

nonisolated extension ApiImportBookPayload {
    /// 将已通过 Android DTO 校验和会话合并的数据转成统一 Draft，供 API 与文件入口共用预览。
    func asNoteImportDraft() -> NoteImportDraftBook {
        var draft = NoteImportDraftBook()
        draft.name = name
        draft.rawName = rawName
        draft.author = author
        draft.authorIntro = authorIntro
        draft.translator = translator
        draft.press = press
        draft.isbn = isbn
        draft.summary = summary
        draft.pubDate = pubDate
        draft.cover = cover
        draft.type = type
        draft.source = source
        draft.sourceName = sourceName
        draft.positionUnit = positionUnit
        draft.currentPositionUnit = positionUnit
        draft.readPosition = readPosition
        draft.totalPosition = totalPosition
        draft.totalPagination = totalPagination
        draft.wordCount = wordCount
        draft.score = score
        draft.purchaseDate = purchaseDate
        draft.price = price
        draft.readStatusID = readStatusId
        draft.readStatusChangedDate = readStatusChangedDate
        draft.wereadUpdateTime = wereadUpdateTime
        draft.group = group.map { NoteImportDraftGroup(name: $0.name) }
        draft.tags = tags.map { NoteImportDraftTag(name: $0.name) }
        draft.notes = noteList.map {
            NoteImportDraftNote(
                content: $0.content,
                idea: $0.idea,
                position: "",
                positionUnit: positionUnit,
                createdTime: $0.createdDateTime,
                chapter: $0.chapter.title.isEmpty ? nil : NoteImportDraftChapter(title: $0.chapter.title),
                attachments: $0.attachImages.map { NoteImportDraftAttachment(imageURL: $0.imageURL) }
            )
        }
        draft.reviews = apiImportReviews.map {
            NoteImportDraftReview(title: $0.title, content: $0.content, createdTime: $0.createdDateTime)
        }
        draft.chapters = apiImportChapterList.map(NoteImportDraftChapter.init)
        draft.preciseReadingDurations = preciseReadingDurations?.map {
            NoteImportPreciseReadingDuration(startTime: $0.startTime, endTime: $0.endTime, position: $0.position)
        }
        draft.fuzzyReadingDurations = fuzzyReadingDurations?.map {
            NoteImportFuzzyReadingDuration(date: $0.date, durationSeconds: $0.durationSeconds, position: $0.position)
        }
        return draft
    }
}

nonisolated extension NoteImportDraftChapter {
    init(_ chapter: ApiImportChapterPayload) {
        title = chapter.title
        remark = chapter.remark
        level = chapter.level
        order = chapter.order
        pathTitles = chapter.pathTitles
        sourceType = chapter.sourceType
        sourceUID = chapter.sourceUID
        sourceAnchor = chapter.sourceAnchor
        sourceOrder = chapter.sourceOrder
        sourcePath = chapter.sourcePath
        children = chapter.children.map(Self.init)
    }
}
