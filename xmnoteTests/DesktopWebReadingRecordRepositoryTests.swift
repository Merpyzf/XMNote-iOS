/**
 * [INPUT]: 依赖 AppDatabase.empty、GRDB Record 与 DesktopWebReadingRecordRepository
 * [OUTPUT]: 验证 6 条阅读计时/记录 API 的排序、校验、事务、软删除及 Android 缺陷兼容边界
 * [POS]: iOS App 隔离数据库单元测试；锁定 Android ReadTimeWebService/ReadingRecordWebService 语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct DesktopWebReadingRecordRepositoryTests {
    @Test
    func timerRejectsContradictoryFieldsAndRequiresLongDurationConfirmation() async throws {
        let fixture = try makeReadingRecordFixture(now: 40_000_000)
        try readingSeedBook(
            fixture.database,
            id: 101,
            readPosition: 10,
            positionUnit: 0
        )

        await expectReadingRecordError(.invalidArgument("开始时间必须早于结束时间")) {
            _ = try await fixture.repository.createReadingSession(.init(
                bookID: 101,
                startTime: 9_000,
                endTime: 8_000,
                elapsedSeconds: 28_801,
                countdownSeconds: 0,
                pausedDurationMillis: 0,
                position: nil,
                recordedPositionUnit: nil,
                insight: nil,
                confirmedLongDuration: false
            ))
        }

        await expectReadingRecordError(.invalidArgument("阅读时长超过 8 小时，请确认后再保存")) {
            _ = try await fixture.repository.createReadingSession(.init(
                bookID: 101,
                startTime: 1_000,
                endTime: 28_802_000,
                elapsedSeconds: 28_801,
                countdownSeconds: 0,
                pausedDurationMillis: 0,
                position: nil,
                recordedPositionUnit: nil,
                insight: nil,
                confirmedLongDuration: false
            ))
        }

        let id = try await fixture.repository.createReadingSession(.init(
            bookID: 101,
            startTime: 1_000,
            endTime: 28_802_000,
            elapsedSeconds: 28_801,
            countdownSeconds: 0,
            pausedDurationMillis: 0,
            position: 20,
            recordedPositionUnit: nil,
            insight: "  感想  ",
            confirmedLongDuration: true
        ))
        let record = try #require(try readingFetchRecord(fixture.database, id: id))
        #expect(record.startTime == 1_000)
        #expect(record.endTime == 28_802_000)
        #expect(record.elapsedSeconds == 28_801)
        #expect(record.countdownSeconds == 0)
        #expect(record.pausedDurationMillis == 0)
        #expect(record.status == 3)
        #expect(record.recordedPositionUnit == 0)
        #expect(record.insight == "感想")
        #expect(record.createdDate == 40_000_000)
        let book = try #require(try readingFetchBook(fixture.database, id: 101))
        #expect(book.readPosition == 20)
        #expect(book.currentPositionUnit == 0)
        #expect(book.updatedDate == 40_000_000)
    }

    @Test
    func listFiltersStatusAndDeletionThenSortsByStartCreatedAndID() async throws {
        let fixture = try makeReadingRecordFixture()
        try readingSeedBook(fixture.database, id: 201)
        try readingSeedBook(fixture.database, id: 202, isDeleted: 1)
        try readingSeedRecord(fixture.database, id: 211, bookID: 201, start: 100, created: 20)
        try readingSeedRecord(fixture.database, id: 212, bookID: 201, start: 100, created: 10)
        try readingSeedRecord(fixture.database, id: 213, bookID: 201, fuzzyDate: 200, created: 5)
        try readingSeedRecord(fixture.database, id: 214, bookID: 201, start: 300, status: 1)
        try readingSeedRecord(fixture.database, id: 215, bookID: 201, start: 400, isDeleted: 1)

        #expect(
            try await fixture.repository.readingRecords(bookID: 201, sortOrder: "asc").map(\.id)
                == [212, 211, 213]
        )
        #expect(
            try await fixture.repository.readingRecords(bookID: 201, sortOrder: "desc").map(\.id)
                == [213, 211, 212]
        )
        await expectReadingRecordError(.notFound("书籍不存在")) {
            _ = try await fixture.repository.readingRecords(bookID: 202, sortOrder: "asc")
        }
    }

    @Test
    func detailRejectsUnfinishedRecordAndChecksBookOwnership() async throws {
        let fixture = try makeReadingRecordFixture()
        try readingSeedBook(fixture.database, id: 301)
        try readingSeedBook(fixture.database, id: 302)
        try readingSeedRecord(fixture.database, id: 311, bookID: 301, start: 10, status: 1)

        await expectReadingRecordError(.notFound("阅读记录不存在")) {
            _ = try await fixture.repository.readingRecord(bookID: 301, recordID: 311)
        }
        await expectReadingRecordError(.notFound("阅读记录不存在")) {
            _ = try await fixture.repository.readingRecord(bookID: 302, recordID: 311)
        }
    }

    @Test
    func accurateCreateDerivesElapsedTimeAndAdvancesBookInSameWrite() async throws {
        let fixture = try makeReadingRecordFixture(now: 50_000)
        try readingSeedBook(
            fixture.database,
            id: 401,
            readPosition: 5,
            totalPagination: 500,
            positionUnit: 2
        )

        let created = try await fixture.repository.createReadingRecord(
            bookID: 401,
            input: readingInput(
                mode: " ACCURATE ",
                startTime: 10_000,
                endTime: 15_999,
                elapsedSeconds: 999,
                position: 120,
                insight: "  exact  "
            )
        )
        #expect(created.elapsedSeconds == 5)
        #expect(created.countdownSeconds == 0)
        #expect(created.pausedDurationMillis == 0)
        #expect(created.position == 120)
        #expect(created.recordedPositionUnit == 2)
        #expect(created.insight == "exact")
        #expect(created.createdTime == 50_000)
        #expect(created.updatedTime == 0)
        let book = try #require(try readingFetchBook(fixture.database, id: 401))
        #expect(book.readPosition == 120)

        await expectReadingRecordError(.invalidArgument("开始时间必须早于结束时间")) {
            _ = try await fixture.repository.createReadingRecord(
                bookID: 401,
                input: readingInput(mode: "accurate", startTime: 10, endTime: 10)
            )
        }
        await expectReadingRecordError(.invalidArgument("结束时间不能晚于当前时间")) {
            _ = try await fixture.repository.createReadingRecord(
                bookID: 401,
                input: readingInput(mode: "accurate", startTime: 49_000, endTime: 50_001)
            )
        }
    }

    @Test
    func fuzzyCreateComparesNaturalDayAndValidatesPositiveDuration() async throws {
        let fixture = try makeReadingRecordFixture(now: 86_400_000)
        try readingSeedBook(fixture.database, id: 501)

        let sameDay = try await fixture.repository.createReadingRecord(
            bookID: 501,
            input: readingInput(
                mode: "fuzzy",
                fuzzyReadDate: 86_400_001,
                elapsedSeconds: 60
            )
        )
        #expect(sameDay.fuzzyReadDate == 86_400_001)
        await expectReadingRecordError(.invalidArgument("阅读日期不能晚于今天")) {
            _ = try await fixture.repository.createReadingRecord(
                bookID: 501,
                input: readingInput(
                    mode: "fuzzy",
                    fuzzyReadDate: 172_800_000,
                    elapsedSeconds: 60
                )
            )
        }
        await expectReadingRecordError(.invalidArgument("阅读时长必须大于 0")) {
            _ = try await fixture.repository.createReadingRecord(
                bookID: 501,
                input: readingInput(mode: "fuzzy", fuzzyReadDate: 80_000_000, elapsedSeconds: 0)
            )
        }
        let created = try await fixture.repository.createReadingRecord(
            bookID: 501,
            input: readingInput(mode: "fuzzy", fuzzyReadDate: 80_000_000, elapsedSeconds: 60)
        )
        #expect(created.mode == "fuzzy")
        #expect(created.startTime == 0)
        #expect(created.endTime == 0)
        #expect(created.fuzzyReadDate == 80_000_000)
    }

    @Test
    func updateRejectsRunningRecordAndPreservesStoredUnitWhenOmitted() async throws {
        let fixture = try makeReadingRecordFixture(now: 90_000)
        try readingSeedBook(fixture.database, id: 601, positionUnit: 0)
        try readingSeedRecord(
            fixture.database,
            id: 611,
            bookID: 601,
            start: 10_000,
            end: 20_000,
            position: 50,
            recordedPositionUnit: 2,
            status: 3,
            created: 123
        )

        let updated = try await fixture.repository.updateReadingRecord(
            bookID: 601,
            recordID: 611,
            input: readingInput(
                mode: "accurate",
                startTime: 30_000,
                endTime: 40_000,
                elapsedSeconds: 1,
                position: 50,
                recordedPositionUnit: nil
            )
        )
        #expect(updated.elapsedSeconds == 10)
        #expect(updated.recordedPositionUnit == 2)
        #expect(updated.createdTime == 123)
        #expect(updated.updatedTime == 90_000)
        let stored = try #require(try readingFetchRecord(fixture.database, id: 611))
        #expect(stored.status == 3)

        try readingSeedRecord(
            fixture.database,
            id: 612,
            bookID: 601,
            start: 10_000,
            end: 20_000,
            status: 1
        )
        await expectReadingRecordError(.notFound("阅读记录不存在")) {
            _ = try await fixture.repository.updateReadingRecord(
                bookID: 601,
                recordID: 612,
                input: readingInput(mode: "accurate", startTime: 30_000, endTime: 40_000)
            )
        }
    }

    @Test
    func updateWithoutPositionClearsSnapshotAndDeleteRejectsUnfinishedRecord() async throws {
        let fixture = try makeReadingRecordFixture(now: 95_000)
        try readingSeedBook(fixture.database, id: 701)
        try readingSeedRecord(
            fixture.database,
            id: 711,
            bookID: 701,
            fuzzyDate: 1_000,
            position: 10,
            recordedPositionUnit: 2,
            created: 100
        )
        try readingSeedRecord(fixture.database, id: 712, bookID: 701, start: 1_000, status: 2)

        let cleared = try await fixture.repository.updateReadingRecord(
            bookID: 701,
            recordID: 711,
            input: readingInput(mode: "fuzzy", fuzzyReadDate: 2_000, elapsedSeconds: 30)
        )
        #expect(cleared.position == 0)
        #expect(cleared.recordedPositionUnit == nil)

        await expectReadingRecordError(.notFound("阅读记录不存在")) {
            try await fixture.repository.deleteReadingRecord(bookID: 701, recordID: 712)
        }
        let deleted = try #require(try readingFetchRecord(fixture.database, id: 712))
        #expect(deleted.isDeleted == 0)
        #expect(deleted.updatedDate == 0)
    }

    @Test
    func positionValidationMatchesBookUnitsAndRejectsInvalidNumbers() async throws {
        let fixture = try makeReadingRecordFixture(now: 100_000)
        try readingSeedBook(
            fixture.database,
            id: 801,
            totalPosition: 300,
            totalPagination: 20,
            positionUnit: 1
        )

        await expectReadingRecordError(.invalidArgument("阅读位置单位不正确")) {
            _ = try await fixture.repository.createReadingRecord(
                bookID: 801,
                input: readingInput(
                    mode: "fuzzy",
                    fuzzyReadDate: 1,
                    position: 1,
                    recordedPositionUnit: 99
                )
            )
        }
        await expectReadingRecordError(.invalidArgument("阅读位置格式不正确")) {
            _ = try await fixture.repository.createReadingRecord(
                bookID: 801,
                input: readingInput(
                    mode: "fuzzy",
                    fuzzyReadDate: 1,
                    position: .infinity,
                    recordedPositionUnit: 1
                )
            )
        }
        await expectReadingRecordError(.invalidArgument("页码应小于总页码(300页)")) {
            _ = try await fixture.repository.createReadingRecord(
                bookID: 801,
                input: readingInput(
                    mode: "fuzzy",
                    fuzzyReadDate: 1,
                    position: 301,
                    recordedPositionUnit: 1
                )
            )
        }
    }
}

private struct ReadingRecordFixture {
    let database: AppDatabase
    let repository: DesktopWebReadingRecordRepository
}

@MainActor
private func makeReadingRecordFixture(now: Int64 = 70_000) throws -> ReadingRecordFixture {
    let database = try AppDatabase.empty()
    return ReadingRecordFixture(
        database: database,
        repository: DesktopWebReadingRecordRepository(database: database, currentTimeMillis: { now })
    )
}

private func readingInput(
    mode: String,
    startTime: Int64? = nil,
    endTime: Int64? = nil,
    fuzzyReadDate: Int64? = nil,
    elapsedSeconds: Int64 = 60,
    position: Double? = nil,
    recordedPositionUnit: Int? = nil,
    insight: String? = nil
) -> DesktopWebReadingRecordInput {
    .init(
        mode: mode,
        startTime: startTime,
        endTime: endTime,
        fuzzyReadDate: fuzzyReadDate,
        elapsedSeconds: elapsedSeconds,
        position: position,
        recordedPositionUnit: recordedPositionUnit,
        insight: insight
    )
}

private func readingSeedBook(
    _ database: AppDatabase,
    id: Int64,
    readPosition: Double = 0,
    totalPosition: Int64 = 0,
    totalPagination: Int64 = 0,
    positionUnit: Int64 = 2,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: 1,
            name: "Book \(id)",
            readPosition: readPosition,
            totalPosition: totalPosition,
            totalPagination: totalPagination,
            currentPositionUnit: positionUnit,
            positionUnit: positionUnit,
            sourceId: 1,
            readStatusId: 1,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func readingSeedRecord(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    start: Int64 = 0,
    end: Int64 = 0,
    fuzzyDate: Int64 = 0,
    elapsedSeconds: Int64 = 60,
    position: Double = 0,
    recordedPositionUnit: Int64? = nil,
    status: Int64 = 3,
    created: Int64 = 0,
    updated: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = ReadTimeRecordRecord(
            id: id,
            bookId: bookID,
            startTime: start,
            endTime: end,
            elapsedSeconds: elapsedSeconds,
            position: position,
            status: status,
            fuzzyReadDate: fuzzyDate,
            recordedPositionUnit: recordedPositionUnit,
            createdDate: created,
            updatedDate: updated,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func readingFetchRecord(_ database: AppDatabase, id: Int64) throws -> ReadTimeRecordRecord? {
    try database.dbPool.read { db in try ReadTimeRecordRecord.fetchOne(db, key: id) }
}

private func readingFetchBook(_ database: AppDatabase, id: Int64) throws -> BookRecord? {
    try database.dbPool.read { db in try BookRecord.fetchOne(db, key: id) }
}

@MainActor
private func expectReadingRecordError(
    _ expected: DesktopWebCatalogRepositoryError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("预期错误：\(expected)")
    } catch let error as DesktopWebCatalogRepositoryError {
        #expect(error == expected)
    } catch {
        Issue.record("错误类型不匹配：\(error)")
    }
}
