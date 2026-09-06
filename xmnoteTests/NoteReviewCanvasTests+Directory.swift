/**
 * [INPUT]: 依赖真实派生目录实现、隔离缓存、可取消元数据源及原回顾测试类
 * [OUTPUT]: 验证目录有界读取、顺序兼容、续建校验、删除身份、百万索引与查询计划
 * [POS]: NoteReviewCanvasTests 的目录阶段限定测试；不读写用户真实书摘，不驱动 UI
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Testing
import GRDB
import UIKit
@testable import xmnote

extension NoteReviewCanvasTests {
    @Test(arguments: [32, 64, 96, 128])
    func stackDirectoryUsesStableCapacityAndAdjacentCursors(capacity: Int) async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 401)
        let index = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        let cursor = NoteReviewCanvasDirectoryCursor { _, _ in index }
        try await cursor.configure(directoryRequest())
        let anchor = try #require(await index.locate(ordinal: Int64(capacity + 4)))
        let group = try #require(await cursor.stack(.containing(anchor.member.record.noteID, capacity: capacity)))
        #expect(group.members.count == capacity && group.id.lowerSlot == Int64(capacity))
        #expect(group.firstOrdinal == Int64(capacity) && group.totalCount == 401)
        #expect(group.members.allSatisfy { $0.slot >= group.id.lowerSlot && $0.slot < group.id.upperSlot })
        let next = try #require(await cursor.stack(.adjacent(group.id, direction: 1)))
        let back = try #require(await cursor.stack(.adjacent(next.id, direction: -1)))
        #expect(back.id == group.id && back.noteIDs == group.noteIDs)
        #expect(Set(next.noteIDs).isDisjoint(with: group.noteIDs))
        #expect(group.previewIDs(currentID: anchor.member.record.noteID).count == 4)
        #expect(group.previewIDs(currentID: anchor.member.record.noteID).first == anchor.member.record.noteID)
        await cursor.close()
    }

    @Test
    func stackDeletionSkipsEmptyBucketsWithoutMovingSurvivorsIntoAnotherStack() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 101)
        let index = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        let cursor = NoteReviewCanvasDirectoryCursor { _, _ in index }
        try await cursor.configure(directoryRequest())
        let anchor = try #require(await index.locate(ordinal: 0))
        let first = try #require(await cursor.stack(.containing(anchor.member.record.noteID, capacity: 32)))
        let middle = try #require(await cursor.stack(.adjacent(first.id, direction: 1)))
        let last = try #require(await cursor.stack(.adjacent(middle.id, direction: 1)))
        for id in middle.noteIDs { try await index.removeConfirmed(noteID: id) }
        let next = try #require(await cursor.stack(.adjacent(first.id, direction: 1)))
        #expect(next.id == last.id && next.noteIDs == last.noteIDs)
        #expect(next.firstOrdinal == 32 && next.totalCount == 69)
        #expect(try await cursor.stack(.containing(middle.noteIDs[0], capacity: 32)) == nil)
        await cursor.close()
    }

    @Test(arguments: [false, true])
    func waterfallDirectoryWindowsPreserveSurvivingColumnsAndRelativePositions(rtl: Bool) throws {
        let viewport = CGSize(width: 402, height: 874)
        func height(_ id: Int64) -> CGFloat { 168 + CGFloat(id % 9) * 17 }
        func build(_ ids: [Int64], previous: NoteReviewCanvasWaterfallGeometry?) throws -> NoteReviewCanvasWaterfallGeometry {
            let frames = previous.map { geometry in Dictionary(uniqueKeysWithValues: geometry.orderedIDs.enumerated().map {
                ($0.element, geometry.frames[$0.offset])
            }) } ?? [:]
            return try .init(ids: ids, heights: ids.map(height), viewport: viewport, generation: 1,
                isRTL: rtl, retainingFrames: frames)
        }
        var geometry = try build(Array(1...128), previous: nil)
        for start in [65, 129, 193, 129, 65, 1] {
            let next = try build(Array(Int64(start)..<Int64(start + 128)), previous: geometry)
            let shared = geometry.orderedIDs.filter { next.indexByID[$0] != nil }
            let id = try #require(shared.first)
            let shift = next.frames[try #require(next.indexByID[id])].minY - geometry.frames[try #require(geometry.indexByID[id])].minY
            for id in shared {
                let from = geometry.frames[try #require(geometry.indexByID[id])]
                let to = next.frames[try #require(next.indexByID[id])]
                #expect(abs(from.minX - to.minX) < 0.001)
                #expect(abs(from.minY + shift - to.minY) < 0.001)
                #expect(next.hitTest(CGPoint(x: to.midX, y: to.midY)) == id)
            }
            for column in next.columnIndexes {
                for pair in zip(column, column.dropFirst()) {
                    #expect(next.frames[pair.1].minY - next.frames[pair.0].maxY >= 15.99)
                }
            }
            #expect(next.orderedIDs.count == 128)
            geometry = next
        }
    }

    @Test(arguments: [false, true])
    func regionalCompositionUsesLocalIndexesAndIdenticalWidthEndpoints(rtl: Bool) throws {
        let snapshot = UUID()
        let style = CanvasOverviewPaperStyle(traits: UITraitCollection())
        let viewport = CGSize(width: 402, height: 874)
        var locals: [(NoteReviewDirectoryGroupID, CanvasOverviewCanvasGeometry)] = []
        for bucket in Int64(3)...5 {
            let sources: [NoteReviewOverviewLayoutSource] = (Int64(1)...32).map { value in
                .init(noteID: bucket * 32 + value, contentHTML: "<p>同一张纸 <strong>稳定排版</strong> \(value)</p>",
                    ideaHTML: value.isMultiple(of: 2) ? "<p>观察留下来的位置</p>" : "", bookTitle: "隔离书籍",
                    chapterTitle: "章节", noteUpdatedDate: 1, bookUpdatedDate: 1, chapterUpdatedDate: 1)
            }
            let notes = CanvasOverviewTextFactory.makeRealNotes(sources, style: style)
            let local = try #require(CanvasOverviewGeometryBuilder.makeCanvas(notes: notes, viewportSize: viewport,
                cardWidth: 220, fixedColumns: 4, isRTL: rtl))
            let group = NoteReviewDirectoryGroupID(snapshotID: snapshot, level: 0, bucket: bucket)
            locals.append((group, local))
        }
        let first = try #require(locals.first)
        var window = NoteReviewCanvasRegionWindow(regionWidth: CanvasOverviewRegionalGeometry.trackWidth(for: first.1), isRTL: rtl)
        for (group, local) in locals {
            let admitted = window.admit(id: group, size: local.contentSize)
            #expect(admitted)
        }
        let composite = try #require(CanvasOverviewRegionalGeometry.compose(locals, window: window))
        for paper in composite.papers {
            let center = CGPoint(x: paper.frame.midX, y: paper.frame.midY)
            #expect(composite.paper(at: center)?.noteID == paper.noteID)
            #expect(composite.indexes(in: paper.visualFrame).contains(paper.index))
        }
        for width: CGFloat in [180, 220, 277, 360] {
            let contents = Dictionary(uniqueKeysWithValues: composite.notes.enumerated().map {
                ($0.offset, CanvasOverviewGeometryBuilder.makeContentGeometry(note: $0.element, width: width))
            })
            let next = try #require(CanvasOverviewRegionalGeometry.reflow(composite, width: width, viewport: viewport,
                contents: contents, anchorID: 140, cancellation: nil))
            #expect(next.notes.map(\.id) == composite.notes.map(\.id))
            #expect(next.columnCount == 4)
            for slice in next.regionSlices {
                let local = CanvasOverviewRegionalGeometry.local(next, slice: slice)
                for paper in local.papers {
                    let global = try #require(next.paper(for: paper.noteID))
                    #expect(abs(global.frame.minX - slice.origin.x - paper.frame.minX) < 0.001)
                    #expect(abs(global.frame.minY - slice.origin.y - paper.frame.minY) < 0.001)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func regionalWindowExtendsWithoutMovingExistingPapersAndStaysBounded(rtl: Bool) throws {
        let snapshot = UUID()
        func id(_ bucket: Int64) -> NoteReviewDirectoryGroupID { .init(snapshotID: snapshot, level: 0, bucket: bucket) }
        var window = NoteReviewCanvasRegionWindow(regionWidth: 1_008, isRTL: rtl)
        for group in NoteReviewCanvasRegionWindow.demand(around: id(10)) {
            let admitted = window.admit(id: group, size: CGSize(width: 1_008, height: 1_550 + CGFloat(group.bucket % 4) * 110))
            #expect(admitted)
        }
        #expect(window.placements.count == 9)
        let before = window.placements
        let oldShift = window.canvasTranslation
        let wanted = NoteReviewCanvasRegionWindow.demand(around: id(13))
        window.retain(wanted: Set(wanted), protected: [])
        for group in wanted {
            let admitted = window.admit(id: group, size: CGSize(width: 1_008, height: 1_550 + CGFloat(group.bucket % 4) * 110))
            #expect(admitted)
        }
        #expect(window.placements.count == 9)
        for bucket in Int64(9)...14 { #expect(window.placements[id(bucket)] == before[id(bucket)]) }
        let anchor = try #require(window.placements[id(13)]).paperBounds.origin
        let zoom: CGFloat = 0.95
        let oldOffset = CGPoint(x: 750, y: 1_300)
        let delta = CGPoint(x: window.canvasTranslation.x - oldShift.x, y: window.canvasTranslation.y - oldShift.y)
        let oldScreen = CGPoint(x: (anchor.x + oldShift.x) * zoom - oldOffset.x,
                                y: (anchor.y + oldShift.y) * zoom - oldOffset.y)
        let newScreen = CGPoint(x: (anchor.x + window.canvasTranslation.x) * zoom - oldOffset.x - delta.x * zoom,
                                y: (anchor.y + window.canvasTranslation.y) * zoom - oldOffset.y - delta.y * zoom)
        #expect(abs(oldScreen.x - newScreen.x) < 0.001 && abs(oldScreen.y - newScreen.y) < 0.001)
        let overBudget = window.admit(id: id(18), size: CGSize(width: 1_008, height: 1_800))
        #expect(!overBudget)
        let placements = Array(window.placements.values)
        for i in placements.indices {
            for j in placements.indices where j > i {
                #expect(!placements[i].paperBounds.intersects(placements[j].paperBounds))
            }
        }
    }

    @Test
    func catalogRetainsRealCountsWithoutReadingBodiesOrMaterializingAllGroups() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 10_000)
        let directory = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        let cursor = NoteReviewCanvasDirectoryCursor { _, _ in directory }
        try await cursor.configure(directoryRequest())
        let originalReads = await fixture.calls
        let catalog = try await cursor.catalog(in: nil, currentID: 3_210)
        #expect(catalog.groups.count <= 24)
        #expect(catalog.groups.reduce(Int64(0)) { $0 + $1.count } == 10_000)
        #expect(catalog.currentPath.last?.isLeaf == true)
        #expect(await fixture.calls == originalReads)
        let inner = try await cursor.catalog(in: try #require(catalog.groups.first).id, currentID: 3_210)
        #expect(inner.groups.count <= 24)
        #expect(inner.groups.reduce(Int64(0)) { $0 + $1.count } == inner.scope.count)
        cursor.close()
        await directory.close()
    }

    @Test
    func productionDirectorySessionKeepsGlobalProgressWithBoundedIdentityWindow() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 10_000)
        let directory = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        let repository = CanvasTestNoteRepository()
        repository.directory = directory
        var settings = NoteReviewSettings.defaultValue
        settings.sortRule = .ordered
        let session = NoteReviewUIKitSession(payload: .init(selectedNoteID: 3_210, currentIndex: 0,
            loadedNoteIDs: [3_210], seedItems: [], settings: settings), repository: repository, usesDirectory: true)
        session.automaticallyPreparesOverview = false
        defer { session.dispose() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.onManifestChanged = { session.onManifestChanged = nil; session.onError = nil; continuation.resume() }
            session.onError = { _ in session.onManifestChanged = nil; session.onError = nil; continuation.resume(throwing: NoteReviewDirectoryError.unavailable) }
            session.start()
        }
        let location = try #require(try await directory.locate(noteID: 3_210))
        #expect(session.count == 10_000)
        #expect(session.loadedCount <= 128)
        #expect(session.currentIndex == Int(location.ordinal))
        #expect(session.noteID(at: session.localCurrentIndex) == 3_210)
        #expect(repository.idReads == 0)
        #expect(repository.directoryOpens == 1)
        let region = try await session.readDirectoryRegion(noteID: 3_210)
        #expect(region.members.count == settings.desktopGroupCapacity)
        #expect(region.stackID?.capacity == settings.desktopGroupCapacity)
        #expect(region.members.contains { $0.record.noteID == 3_210 })
        #expect(repository.sourceReads == 0)
        if case .noteReviewDirectory(let reference) = session.detailSource {
            let distant = try await reference.provider?.page(around: .ordinal(9_000))
            #expect(distant?.totalCount == 10_000)
            #expect(distant?.focus?.ordinal == 9_000)
            #expect(session.currentNoteID == 3_210)
            let decoded = try JSONDecoder().decode(NoteReviewDirectoryReference.self,
                from: JSONEncoder().encode(reference))
            #expect(decoded.id == reference.id)
            #expect(decoded.provider == nil)
        } else { Issue.record("Production detail navigation copied IDs instead of borrowing the directory") }
        await directory.close()
    }

    @Test
    func directoryCursorFailedOpenCanRetryWithoutLosingSharedHandle() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 33)
        let directory = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        var opens = 0
        let cursor = NoteReviewCanvasDirectoryCursor { _, _ in
            opens += 1
            if opens == 1 { throw NoteReviewDirectoryError.unavailable }
            return directory
        }
        await #expect(throws: NoteReviewDirectoryError.unavailable) { try await cursor.configure(directoryRequest()) }
        try await cursor.configure(directoryRequest())
        try await cursor.configure(directoryRequest())
        #expect(opens == 2)
        #expect(try await cursor.page(around: .ordinal(32))?.totalCount == 33)
        cursor.close()
        await #expect(throws: CancellationError.self) { _ = try await cursor.page(around: .ordinal(0)) }
        await directory.close()
    }

    @Test
    func firstRegionalDesktopDoesNotPrepareWaterfallUntilRequested() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        controller.currentNoteID = 17
        var batches: [[Int64]] = []
        controller.sourceReader = { ids, _ in
            batches.append(ids)
            return ids.map { .init(noteID: $0,
                contentHTML: "<p>中英文 <strong>continuous paper</strong> <em>阅读</em> 🎉 <del>旧内容</del></p>",
                ideaHTML: "<p>当前区域</p>", bookTitle: "隔离书籍", chapterTitle: "章节", noteUpdatedDate: 1,
                bookUpdatedDate: 1, chapterUpdatedDate: 1) }
        }
        defer { controller.disposeCanvas() }
        let style = CanvasOverviewPaperStyle(traits: UITraitCollection())
        let model = try #require(try await controller.prepareModel(ids: Array(1...32), style: style, waterfallStyle: style,
            size: CGSize(width: 402, height: 874), scale: 3, width: 220, packing: .compactPairs,
            work: CanvasOverviewTransitionPreparation(), preparesWaterfall: false))
        #expect(!model.isWaterfallPrepared)
        #expect(model.canvasGeometry.papers.count == 32)
        #expect(model.waterfallGeometry.frames.isEmpty)
        #expect(batches.flatMap { $0 }.count == 32)
        controller.preparedModel = model
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.onReady = { controller.onReady = nil; continuation.resume() }
            controller.onPreparationChanged = { _, error in
                if error != nil { continuation.resume(throwing: NoteReviewDirectoryError.unavailable) }
            }
            #expect(!controller.ensureWaterfallPrepared())
        }
        #expect(controller.preparedModel?.isWaterfallPrepared == true)
        #expect(controller.preparedModel?.waterfallGeometry.frames.count == 32)
        #expect(batches.flatMap { $0 }.count == 32)
        #expect(controller.ensureWaterfallPrepared())
        #expect(batches.flatMap { $0 }.count == 32)
    }

    @Test
    func productionWaterfallPreparesOnlyRequestedWindowAndKeepsDesktopIndependent() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 10_000)
        let directory = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        controller.currentNoteID = 17
        var bodyReads = 0
        var pageReads = 0
        controller.sourceReader = { ids, _ in
            #expect(ids.count <= 128)
            bodyReads += ids.count
            return ids.map { .init(noteID: $0, contentHTML: "<p>可读的真实富文本 <strong>\($0)</strong></p>",
                ideaHTML: "", bookTitle: "隔离书籍", chapterTitle: "独立瀑布流", noteUpdatedDate: 1,
                bookUpdatedDate: 1, chapterUpdatedDate: 1) }
        }
        controller.directoryWaterfallPageReader = { id in
            pageReads += 1
            return try await directory.page(around: .noteID(id), limit: 128)
        }
        defer { controller.disposeCanvas() }
        let style = CanvasOverviewPaperStyle(traits: UITraitCollection())
        let model = try #require(try await controller.prepareModel(ids: Array(1...32), style: style, waterfallStyle: style,
            size: CGSize(width: 402, height: 874), scale: 3, width: 220, packing: .compactPairs,
            work: CanvasOverviewTransitionPreparation(), preparesWaterfall: false))
        controller.preparedModel = model
        controller.currentNoteID = 8_000
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.onReady = { controller.onReady = nil; controller.onPreparationChanged = nil; continuation.resume() }
            controller.onPreparationChanged = { _, error in
                if error != nil {
                    controller.onReady = nil; controller.onPreparationChanged = nil
                    continuation.resume(throwing: NoteReviewDirectoryError.unavailable)
                }
            }
            #expect(!controller.ensureWaterfallPrepared())
        }
        let ready = try #require(controller.preparedModel)
        #expect(ready.notes.map(\.id) == Array(1...32))
        #expect(ready.waterfallGeometry.frames.count == 128)
        #expect(ready.waterfallGeometry.indexByID[8_000] != nil)
        #expect(ready.content(for: 8_000, mode: .waterfall)?.preparedBlocks?.isEmpty == false)
        #expect(ready.content(for: 8_000, mode: .desktop) == nil)
        #expect(controller.directoryWaterfallPage?.totalCount == 10_000)
        #expect(bodyReads == 160 && pageReads == 1)
        #expect(controller.ensureWaterfallPrepared())
        #expect(bodyReads == 160 && pageReads == 1)
        let page = try #require(controller.directoryWaterfallPage)
        controller.canCommitBackgroundGeometry = { false }
        controller.pendingWaterfallPage = (page, ready.waterfallGeometry)
        controller.applyPendingWaterfallPage()
        #expect(controller.pendingWaterfallPage != nil)
        controller.canCommitBackgroundGeometry = { true }
        controller.applyPendingWaterfallPage()
        #expect(controller.pendingWaterfallPage == nil)
        controller.pauseCanvas()
        #expect(controller.waterfallPageTask == nil && controller.pendingWaterfallPage == nil)
        await directory.close()
    }

    @Test
    func directoryRealSourcePreservesFiltersAndUsesPrimaryKeySeek() async throws {
        let (folder, _) = try directoryTestURL()
        let source = try AppDatabase(path: folder.appendingPathComponent("source.sqlite").path)
        defer { try? source.close(); try? FileManager.default.removeItem(at: folder) }
        try await source.dbPool.write { db in
            for id in Int64(10)...11 {
                var book = BookRecord(id: id, userId: 1, name: "隔离目录书籍", readStatusId: 1, updatedDate: id * 10)
                try book.insert(db)
                var tag = TagRecord(id: id, userId: 1, name: "隔离目录标签", type: 1)
                try tag.insert(db)
            }
            for id in Int64(1)...64 {
                var note = NoteRecord(id: id, bookId: id.isMultiple(of: 2) ? 10 : 11,
                    content: "<p><strong>目录不得读取的真实富文本</strong></p>", updatedDate: id)
                try note.insert(db)
                if id.isMultiple(of: 3) {
                    var link = TagNoteRecord(tagId: 10, noteId: id)
                    try link.insert(db)
                }
                if id.isMultiple(of: 5) {
                    var link = TagNoteRecord(tagId: 11, noteId: id)
                    try link.insert(db)
                }
            }
        }
        var settings = NoteReviewSettings.defaultValue
        settings.selectedBookIDs = [10]
        settings.selectedTagIDs = [10, 11]
        settings.tagMatchRule = .all
        let query = NoteReviewDirectorySourceQuery(request: .init(settings: settings, seed: 1))
        let result = try await source.dbPool.read { db in
            (try query.read(db, after: nil, limit: 128), try query.queryPlan(db, after: 30))
        }
        #expect(result.0.map(\.noteID) == [30, 60])
        #expect(result.0.allSatisfy { $0.bookRevision == 100 && $0.chapterRevision == 0 })
        #expect(result.1.contains { $0.contains("SEARCH n") && $0.contains("rowid>?") })
        #expect(result.1.contains { $0.contains("index_tag_note_note_id") && $0.contains("note_id=?") })
        #expect(!result.1.contains { $0.contains("LIST SUBQUERY") || $0.contains("GROUP BY") })
        let next = try await source.dbPool.read { try query.read($0, after: 30, limit: 128) }
        #expect(next.map(\.noteID) == [60])
        for rule in [NoteReviewTagMatchRule.any, .all] {
            settings.selectedBookIDs = [10, 11]
            settings.tagMatchRule = rule
            let multiple = NoteReviewDirectorySourceQuery(request: .init(settings: settings, seed: 1))
            let rows = try await source.dbPool.read { try multiple.read($0, after: 17, limit: 128) }
            let expected = (Int64(18)...64).filter {
                rule == .all ? $0.isMultiple(of: 15) : $0.isMultiple(of: 3) || $0.isMultiple(of: 5)
            }
            #expect(rows.map(\.noteID) == expected)
            let plan = try await source.dbPool.read { try multiple.queryPlan($0, after: 17) }
            #expect(plan.contains { $0.contains("SEARCH n") && $0.contains("rowid>?") })
            #expect(plan.contains { $0.contains("index_tag_note_note_id") && $0.contains("note_id=?") })
            #expect(!plan.contains { $0.contains("ORDER BY") || $0.contains("LIST SUBQUERY") })
        }
    }

    @Test
    func directoryTaskCancellationStopsBeforeNextReadAndCanResume() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 4_000)
        let request = directoryRequest()
        let task = Task {
            try await NoteReviewDirectoryIndex.open(at: url, request: request, reader: fixture.reader, progress: { state in
                if case .scanning(let count) = state, count >= 1_024 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await fixture.calls == 1)
        let resumed = try await NoteReviewDirectoryIndex.open(at: url, request: request, reader: fixture.reader)
        #expect(try await resumed.root().count == 4_000)
        await resumed.close()
    }

    @Test(arguments: [0, 1, 32, 33, 128])
    func directoryTreeHasBoundedLeavesAndExactProgress(count: Int) async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: Int64(count))
        let index = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        let root = try await index.root()
        #expect(root.count == count)
        var leaves = [NoteReviewDirectoryGroup]()
        var queue = [root]
        while !queue.isEmpty {
            let group = queue.removeFirst()
            if group.isLeaf { leaves.append(group) } else {
                let children = try await index.children(of: group.id)
                #expect(children.count <= 4)
                #expect(children.reduce(Int64(0)) { $0 + $1.count } == group.count)
                queue += children
            }
        }
        var previous: NoteReviewDirectoryMember?
        var ordinal: Int64 = 0
        for leaf in leaves {
            let members = try await index.members(in: leaf.id)
            #expect(members.count <= 32)
            for member in members {
                if let previous {
                    #expect(previous.record.bookID >= member.record.bookID)
                    if previous.record.bookID == member.record.bookID { #expect(previous.record.noteID < member.record.noteID) }
                }
                let location = try #require(await index.locate(noteID: member.record.noteID))
                #expect(location.ordinal == ordinal)
                #expect(location.path.last?.id == leaf.id)
                #expect(try await index.locate(ordinal: ordinal) == location)
                previous = member
                ordinal += 1
            }
        }
        #expect(ordinal == count)
        #expect(try await index.locate(ordinal: -1) == nil)
        #expect(try await index.locate(ordinal: Int64(count)) == nil)
        await index.close()
        await #expect(throws: NoteReviewDirectoryError.closed) { try await index.root() }
    }

    @Test
    func directorySeedAndExistingPrefixAreStableAndMissingIDsDoNotBlock() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 128)
        let request = directoryRequest(sort: .random, prefix: [74, 3, 74, 999, 55])
        let first = try await NoteReviewDirectoryIndex.open(at: url, request: request, reader: fixture.reader)
        let members = try await first.window(after: nil, limit: 999_999)
        #expect(members.count == 128)
        #expect(Array(members.prefix(3).map(\.record.noteID)) == [74, 3, 55])
        #expect(Set(members.map(\.record.noteID)).count == 128)
        let staleGroup = try await first.root().id
        await first.close()
        let second = try await NoteReviewDirectoryIndex.open(at: url, request: request, reader: fixture.reader)
        #expect(try await second.window(after: nil, limit: 128) == members)
        await #expect(throws: NoteReviewDirectoryError.invalidGroup) { try await second.members(in: staleGroup) }
        await second.close()
    }

    @Test
    func directoryOrderedScopeDoesNotApplyRandomLaunchPrefix() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 20)
        let request = directoryRequest(sort: .ordered, prefix: [1, 2, 3])
        #expect(request.preservedIDs.isEmpty)
        let index = try await NoteReviewDirectoryIndex.open(at: url, request: request, reader: fixture.reader)
        #expect(try await index.window(after: nil, limit: 1).first?.record.noteID == 13)
        await index.close()
    }

    @Test
    func directoryDeletionKeepsLeafIdentityAndUsesAncestorCounts() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 128)
        let index = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        let before = try #require(await index.locate(noteID: 2))
        let head = try #require(await index.window(after: nil, limit: 1).first)
        try await index.removeConfirmed(noteID: head.record.noteID)
        try await index.removeConfirmed(noteID: head.record.noteID)
        let after = try #require(await index.locate(noteID: 2))
        #expect(before.member.slot == after.member.slot)
        #expect(before.path.map(\.id) == after.path.map(\.id))
        #expect(after.ordinal == before.ordinal - 1)
        #expect(try await index.root().count == 127)
        #expect(try await index.locate(noteID: head.record.noteID) == nil)
        #expect(try await index.locate(ordinal: after.ordinal) == after)
        let previous = try await index.window(before: after.member.slot, limit: 128)
        #expect(previous.count == after.ordinal)
        #expect(previous.allSatisfy { $0.slot < after.member.slot })
        await index.close()
    }

    @Test
    func directoryEmptyLeafAndAllDeletedKeepExactCounts() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 33)
        let index = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        let original = try await index.window(after: nil, limit: 128)
        let first = try #require(await index.locate(ordinal: 0))
        let leafID = try #require(first.path.last?.id)
        for member in original.prefix(32) { try await index.removeConfirmed(noteID: member.record.noteID) }
        #expect(try await index.group(leafID) == nil)
        #expect(try await index.members(in: leafID).isEmpty)
        let remaining = try #require(await index.locate(ordinal: 0))
        #expect(remaining.member == original.last)
        #expect(remaining.ordinal == 0)
        #expect(try await index.window(before: remaining.member.slot, limit: 128).isEmpty)
        try await index.removeConfirmed(noteID: remaining.member.record.noteID)
        #expect(try await index.root().count == 0)
        #expect(try await index.locate(ordinal: 0) == nil)
        #expect(try await index.children(of: first.path[0].id).isEmpty)
        await index.close()
    }

    @Test
    func directoryCancelledOrderingResumesWithoutDuplicateSlots() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 4_000)
        let request = directoryRequest(sort: .random)
        let task = Task {
            try await NoteReviewDirectoryIndex.open(at: url, request: request, reader: fixture.reader, progress: { state in
                if case .indexing(let count) = state, count >= 1_024 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let index = try await NoteReviewDirectoryIndex.open(at: url, request: request, reader: fixture.reader)
        var cursor: Int64?
        var count = 0
        var seen = Set<Int64>()
        while true {
            let batch = try await index.window(after: cursor, limit: 128)
            if batch.isEmpty { break }
            for member in batch {
                #expect(member.slot == Int64(count))
                #expect(seen.insert(member.record.noteID).inserted)
                count += 1
            }
            cursor = batch.last?.slot
        }
        #expect(count == 4_000)
        await index.close()
    }

    @Test
    func directoryReadingPagesKeepGlobalProgressAndBoundedIdentity() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 10_000)
        let index = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(sort: .random), reader: fixture.reader)
        for ordinal in [Int64(0), 127, 5_000, 9_999] {
            let page = try #require(await index.page(around: .ordinal(ordinal), limit: 1_000_000))
            #expect(page.members.count <= 128 && page.totalCount == 10_000)
            let focus = try #require(page.focus)
            #expect(focus.ordinal == ordinal)
            #expect(page.member(at: ordinal) == focus.member)
            #expect(page.member(at: page.firstOrdinal - 1) == nil)
            #expect(page.member(at: page.firstOrdinal + Int64(page.members.count)) == nil)
            #expect(try await index.page(around: .noteID(focus.member.record.noteID), limit: 128) == page)
        }
        let page = try #require(await index.page(around: .ordinal(5_000), limit: 128))
        let deleted = page.members[0]
        let focusID = try #require(page.focus).member.record.noteID
        try await index.removeConfirmed(noteID: deleted.record.noteID)
        let updated = try #require(await index.page(around: .noteID(focusID), limit: 128))
        #expect(updated.totalCount == 9_999)
        #expect(updated.focus?.ordinal == 4_999)
        #expect(!updated.members.contains { $0.record.noteID == deleted.record.noteID })
        #expect(try await index.page(around: .noteID(deleted.record.noteID), limit: 128) == nil)
        #expect(try await index.page(around: .ordinal(99_999), limit: 128) == nil)
        await index.close()
    }

    @Test
    func directoryCancelledScanResumesOnlyAfterRevisionValidation() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 4_000)
        await fixture.setFailure(after: 1_024)
        await #expect(throws: CancellationError.self) {
            _ = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        }
        #expect(await fixture.calls == 2)
        await fixture.setFailure(after: nil)
        await fixture.changeRevision(of: 17)
        let resumed = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        #expect(try await resumed.root().count == 4_000)
        #expect(try await resumed.locate(noteID: 17)?.member.record.noteRevision == 99_999)
        #expect(await fixture.maximumBatch <= 1_024)
        await resumed.close()
    }

    @Test
    func directoryValidationDetectsSameCountSameMaximumRevisionMembershipChange() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 128)
        let index = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        await index.close()
        await fixture.replaceFirstMember()
        let updated = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        #expect(try await updated.root().count == 128)
        #expect(try await updated.locate(noteID: 1) == nil)
        #expect(try await updated.locate(noteID: 129) != nil)
        await updated.close()
    }

    @Test
    func directoryRejectsBadProducerAndHonorsDiskBudget() async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: 20)
        await #expect(throws: NoteReviewDirectoryError.cacheBudgetExceeded) {
            _ = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), byteBudget: 512, reader: fixture.reader)
        }
        let row = NoteReviewDirectoryRecord(noteID: 1, bookID: 1, chapterID: 0, noteRevision: 1, bookRevision: 1, chapterRevision: 0)
        await #expect(throws: NoteReviewDirectoryError.invalidBatch) {
            _ = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: { _, _ in [row, row] })
        }
        // 失败必须释放文件资格，不能使重试永久处于 cacheInUse。
        let valid = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(), reader: fixture.reader)
        #expect(try await valid.root().count == 20)
        await valid.close()
    }

    @Test(arguments: [Int64(10_000), 1_000_000])
    func directoryLargeMetadataUsesDiskAndBoundedWindows(count: Int64) async throws {
        let (folder, url) = try directoryTestURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DirectoryFixture(count: count)
        let index = try await NoteReviewDirectoryIndex.open(at: url, request: directoryRequest(sort: .random), reader: fixture.reader)
        #expect(try await index.root().count == count)
        #expect(await fixture.maximumBatch <= 1_024)
        #expect(await fixture.calls <= Int((count + 1_023) / 1_024) + 1)
        for id in [Int64(1), count / 2, count] {
            let location = try #require(await index.locate(noteID: id))
            #expect(location.localIndex < 32 && location.ordinal < count)
            #expect(location.path.count <= 9)
            #expect(try await index.locate(ordinal: location.ordinal) == location)
            let leaf = try #require(location.path.last)
            #expect(try await index.members(in: leaf.id).count <= 32)
            #expect(try await index.window(after: location.member.slot, limit: 1_000_000).count <= 128)
            let page = try #require(await index.page(around: .noteID(id), limit: 1_000_000))
            #expect(page.members.count <= 128 && page.totalCount == count)
            #expect(page.member(at: location.ordinal) == location.member)
        }
        let diagnostic = try await index.diagnostics()
        #expect(diagnostic.bytes < NoteReviewDirectoryIndex.diskBudget)
        #expect(diagnostic.windowPlan.contains { $0.contains("positions_slot") && $0.contains("SEARCH") })
        await index.close()
    }

    private func directoryRequest(sort: NoteReviewSortRule = .ordered, prefix: [Int64] = []) -> NoteReviewDirectoryRequest {
        var settings = NoteReviewSettings.defaultValue
        settings.sortRule = sort
        return .init(settings: settings, seed: 42, preservedIDs: prefix)
    }

    private func directoryTestURL() throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NoteReviewDirectoryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, folder.appendingPathComponent("directory.sqlite"))
    }
}

/// 模拟的是不同书/章/revision 的轻量记录；始终按需生成一批，不创建百万个 ID 或假正文常驻数组。
private actor DirectoryFixture {
    private let count: Int64
    private var failureAfter: Int64?
    private var changedID: Int64?
    private var replaced = false
    private(set) var calls = 0
    private(set) var maximumBatch = 0

    nonisolated var reader: NoteReviewDirectoryIndex.Reader {
        { [self] cursor, limit in try await read(after: cursor, limit: limit) }
    }

    init(count: Int64) { self.count = count }
    func setFailure(after value: Int64?) { failureAfter = value }
    func changeRevision(of id: Int64) { changedID = id }
    func replaceFirstMember() { replaced = true }

    func read(after: Int64?, limit: Int) throws -> [NoteReviewDirectoryRecord] {
        calls += 1
        let cursor = after ?? 0
        if let failureAfter, cursor >= failureAfter { throw CancellationError() }
        let first = max(replaced ? 2 : 1, cursor + 1)
        let end = min(count + (replaced ? 1 : 0) + 1, first + Int64(limit))
        guard first < end else { return [] }
        let batch = (first..<end).map { id in
            NoteReviewDirectoryRecord(noteID: id, bookID: id / 13 + 1, chapterID: id / 5,
                noteRevision: id == changedID ? 99_999 : 1_720_000_000_000 + id % 127,
                bookRevision: 1_710_000_000_000 + id / 13 % 31, chapterRevision: 1_715_000_000_000 + id / 5 % 19)
        }
        maximumBatch = max(maximumBatch, batch.count)
        return batch
    }
}
