import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 read_time_record/book 表与 BookReadStatusMutation 完成计时记录写入
 * [OUTPUT]: 对外提供 ReadingTimerRepository（ReadingTimerRepositoryProtocol 的 GRDB 实现，保持 Android 暂停历史与读完状态写入语义）
 * [POS]: Data 层阅读计时仓储实现，统一封装实时计时、停止待保存、完成保存、补录和恢复查询
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读计时仓储实现，负责把 iOS 计时流程写入 Android 兼容的 `read_time_record` 数据口径。
nonisolated struct ReadingTimerRepository: ReadingTimerRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let calendar: Calendar
    private let userDefaults: UserDefaults

    /// 注入数据库管理器，供计时记录与书籍进度写入复用同一数据源。
    init(
        databaseManager: DatabaseManager,
        calendar: Calendar = .current,
        userDefaults: UserDefaults = .standard
    ) {
        self.databaseManager = databaseManager
        self.calendar = calendar
        self.userDefaults = userDefaults
    }

    /// 每次数据库操作都从 DatabaseManager 读取当前连接池，避免备份恢复后继续使用旧 DatabasePool。
    private func currentDatabasePool() async -> DatabasePool {
        await MainActor.run {
            databaseManager.database.dbPool
        }
    }

    /// 读取单本有效书籍的计时上下文。
    nonisolated func fetchBookContext(bookId: Int64) async throws -> ReadingTimerBookContext {
        let dbPool = await currentDatabasePool()
        return try await dbPool.read { db in
            guard let book = try fetchBookContext(db, bookId: bookId) else {
                throw ReadingTimerError.bookNotFound
            }
            return book
        }
    }

    /// 读取全局最新可恢复计时，供冷启动和回前台恢复。
    nonisolated func fetchActiveSession() async throws -> ReadingTimerSession? {
        let dbPool = await currentDatabasePool()
        return try await dbPool.read { db in
            try fetchActiveSession(db)
        }
    }

    /// 按记录 ID 读取阅读计时详情。
    nonisolated func fetchSession(recordId: Int64) async throws -> ReadingTimerSession? {
        let dbPool = await currentDatabasePool()
        return try await dbPool.read { db in
            try fetchSession(db, recordId: recordId)
        }
    }

    /// 创建新的运行中计时记录，并按 Android 业务意图把书籍状态推进为在读。
    nonisolated func createSession(bookId: Int64, startAt: Date, countdownSeconds: Int64) async throws -> ReadingTimerSession {
        guard countdownSeconds >= 0 else {
            throw ReadingTimerError.invalidDuration
        }
        let startMillis = Self.timestampMillis(from: startAt)
        let dbPool = await currentDatabasePool()
        let session = try await dbPool.write { db in
            if try fetchActiveSession(db) != nil {
                throw ReadingTimerError.activeSessionExists
            }
            guard let book = try fetchBookContext(db, bookId: bookId) else {
                throw ReadingTimerError.bookNotFound
            }

            var record = ReadTimeRecordRecord()
            record.bookId = bookId
            record.startTime = startMillis
            record.endTime = 0
            record.interruptTime = 0
            record.elapsedSeconds = 0
            record.countdownSeconds = countdownSeconds
            record.pausedDurationMillis = 0
            record.paused = 0
            record.position = 0
            record.status = ReadingTimerRecordStatus.running.rawValue
            record.fuzzyReadDate = 0
            record.wereadReadDate = 0
            record.insight = ""
            record.recordedPositionUnit = nil
            record.createdDate = startMillis
            record.updatedDate = 0
            record.lastSyncDate = 0
            record.isDeleted = 0
            try record.insert(db)

            if book.readStatusId != BookEntryReadingStatus.reading.rawValue {
                try BookReadStatusMutation.updateBookReadStatus(
                    db,
                    bookID: bookId,
                    statusID: BookEntryReadingStatus.reading.rawValue,
                    changedAt: startMillis,
                    updatedAt: startMillis,
                    finishedRatingScore: nil
                )
            }

            guard let recordId = record.id,
                  let session = try fetchSession(db, recordId: recordId) else {
                throw ReadingTimerError.sessionNotFound
            }
            return session
        }
        syncAndroidPendingTimingRecordId(for: session)
        return session
    }

    /// 持久化计时快照，覆盖运行、暂停和停止待保存三种未完成状态。
    nonisolated func updateSessionSnapshot(_ input: ReadingTimerSnapshotInput) async throws -> ReadingTimerSession {
        guard input.status.isUnfinished else {
            throw ReadingTimerError.unsupportedStatus(input.status.rawValue)
        }
        guard !input.expectedStatuses.isEmpty,
              input.expectedStatuses.allSatisfy(\.isUnfinished) else {
            throw ReadingTimerError.unsupportedStatus(input.status.rawValue)
        }
        guard input.elapsedSeconds >= 0, input.pausedDurationMillis >= 0 else {
            throw ReadingTimerError.invalidDuration
        }

        let dbPool = await currentDatabasePool()
        let session = try await dbPool.write { db in
            guard try fetchSession(db, recordId: input.recordId) != nil else {
                throw ReadingTimerError.sessionNotFound
            }

            let now = Self.currentTimestampMillis
            let interruptMillis = Self.timestampMillis(from: input.interruptAt) ?? now
            let endMillis: Int64
            if input.status == .stoppedPendingSave {
                endMillis = Self.timestampMillis(from: input.endAt) ?? interruptMillis
            } else {
                endMillis = 0
            }
            let pausedFlag = try resolvedPausedFlag(
                db,
                recordId: input.recordId,
                incomingStatus: input.status,
                incomingPausedDurationMillis: input.pausedDurationMillis
            )
            let expectedStatusValues = input.expectedStatuses.map(\.rawValue)
            let expectedStatusPlaceholders = expectedStatusValues.map { _ in "?" }.joined(separator: ", ")

            // SQL 目的：更新未完成阅读计时快照，并按调用方声明的原状态收窄状态机迁移。
            // 涉及表：read_time_record。
            // 关键过滤：id 精确命中、is_deleted = 0、status IN expectedStatuses；运行态节流只允许 running，暂停/继续/结束只允许各自合法前置状态，避免旧快照覆盖 paused 或 stoppedPendingSave。
            // 时间字段：interrupt_time/end_time/updated_date 均为 Android 毫秒时间戳；elapsed_seconds 是已扣除暂停的实际阅读秒数；paused 表示本次计时是否曾暂停过。
            // 副作用用途：为 App 回前台、冷启动恢复和 Android 端未完成计时恢复提供最新状态。
            let sql = """
                UPDATE read_time_record
                SET status = ?,
                    elapsed_seconds = ?,
                    paused_duration_millis = ?,
                    paused = ?,
                    interrupt_time = ?,
                    end_time = ?,
                    updated_date = ?
                WHERE id = ?
                  AND is_deleted = 0
                  AND status IN (\(expectedStatusPlaceholders))
                """
            let arguments = StatementArguments([
                input.status.rawValue,
                input.elapsedSeconds,
                input.pausedDurationMillis,
                pausedFlag,
                interruptMillis,
                endMillis,
                now,
                input.recordId
            ] + expectedStatusValues)
            try db.execute(
                sql: sql,
                arguments: arguments
            )

            let changedRows = try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
            guard changedRows > 0 else {
                throw ReadingTimerError.staleSessionState
            }

            guard let session = try fetchSession(db, recordId: input.recordId),
                  session.status == input.status else {
                throw ReadingTimerError.sessionNotFound
            }
            return session
        }
        syncAndroidPendingTimingRecordId(for: session)
        return session
    }

    /// 继续停止待保存的计时；停止到继续之间的间隔按暂停处理，避免恢复后把离场时间计入阅读。
    nonisolated func resumeStoppedSession(recordId: Int64, resumedAt: Date) async throws -> ReadingTimerSession {
        let resumedMillis = Self.timestampMillis(from: resumedAt)
        let dbPool = await currentDatabasePool()
        let session = try await dbPool.write { db in
            guard let current = try fetchSession(db, recordId: recordId),
                  current.status == .stoppedPendingSave,
                  current.startTime != nil,
                  current.countdownSeconds == 0 || current.elapsedSeconds < current.countdownSeconds else {
                throw ReadingTimerError.staleSessionState
            }

            let stoppedAt = current.endTime ?? current.interruptTime ?? resumedAt
            let stoppedGapMillis = max(0, resumedMillis - Self.timestampMillis(from: stoppedAt))
            let resumedPausedDurationMillis = current.pausedDurationMillis + stoppedGapMillis

            // SQL 目的：把停止待保存记录恢复为运行态，同时把停止间隔计入暂停累计。
            // 涉及表：read_time_record。
            // 关键过滤：id 精确命中、is_deleted = 0、status = 2，确保完成或已恢复记录不会被旧操作覆盖。
            // 时间字段：保留原 start_time；end_time 清零；interrupt_time/updated_date 写恢复时刻毫秒时间戳；paused_duration_millis 累加停止间隔。
            // 副作用用途：进程恢复后仍能按原开始时间继续计时，且离场时段不进入有效阅读时长。
            let sql = """
                UPDATE read_time_record
                SET status = ?,
                    end_time = 0,
                    interrupt_time = ?,
                    paused_duration_millis = ?,
                    paused = 1,
                    updated_date = ?
                WHERE id = ?
                  AND is_deleted = 0
                  AND status = ?
                """
            try db.execute(
                sql: sql,
                arguments: [
                    ReadingTimerRecordStatus.running.rawValue,
                    resumedMillis,
                    resumedPausedDurationMillis,
                    resumedMillis,
                    recordId,
                    ReadingTimerRecordStatus.stoppedPendingSave.rawValue
                ]
            )
            let changedRows = try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
            guard changedRows > 0,
                  let resumed = try fetchSession(db, recordId: recordId),
                  resumed.status == .running else {
                throw ReadingTimerError.staleSessionState
            }
            return resumed
        }
        syncAndroidPendingTimingRecordId(for: session)
        return session
    }

    /// 保存停止后的计时记录，使记录进入 `status = 3` 的既有统计消费口径。
    nonisolated func finishSession(_ input: ReadingTimerFinishInput) async throws -> ReadingTimerSession {
        guard input.measuredElapsedSeconds >= 0, input.measuredPausedDurationMillis >= 0 else {
            throw ReadingTimerError.invalidDuration
        }

        let dbPool = await currentDatabasePool()
        let result = try await dbPool.write { db in
            guard let current = try fetchSession(db, recordId: input.recordId),
                  current.status.isUnfinished else {
                throw ReadingTimerError.sessionNotFound
            }
            guard input.targetBookId > 0,
                  let targetBook = try fetchBookContext(db, bookId: input.targetBookId) else {
                throw ReadingTimerError.bookNotFound
            }
            guard input.endAt > input.startAt, input.endAt <= Date() else {
                throw ReadingTimerError.invalidTimeRange
            }

            let recordedPositionUnit: Int64?
            let storedPosition: Double
            if let position = input.position {
                try validateReadPosition(
                    position,
                    positionUnit: targetBook.positionUnit,
                    totalPosition: targetBook.totalPosition,
                    totalPagination: targetBook.totalPagination
                )
                recordedPositionUnit = targetBook.positionUnit
                storedPosition = position
            } else {
                recordedPositionUnit = nil
                storedPosition = 0
            }

            let now = Self.currentTimestampMillis
            let startMillis = Self.timestampMillis(from: input.startAt)
            let endMillis = Self.timestampMillis(from: input.endAt)
            let insight = Self.normalizedInsight(input.insight)
            let storedElapsedSeconds: Int64
            let storedPausedDurationMillis: Int64
            let pausedFlag: Int64
            if input.didEditTimeRange {
                storedElapsedSeconds = Int64(input.endAt.timeIntervalSince(input.startAt))
                storedPausedDurationMillis = 0
                pausedFlag = 0
            } else {
                storedElapsedSeconds = input.measuredElapsedSeconds
                storedPausedDurationMillis = max(
                    input.measuredPausedDurationMillis,
                    current.pausedDurationMillis
                )
                pausedFlag = try resolvedPausedFlag(
                    db,
                    recordId: input.recordId,
                    incomingStatus: current.status,
                    incomingPausedDurationMillis: storedPausedDurationMillis
                )
            }
            guard storedElapsedSeconds > 0 else {
                throw ReadingTimerError.invalidDuration
            }
            let arguments: StatementArguments = [
                ReadingTimerRecordStatus.finished.rawValue,
                input.targetBookId,
                startMillis,
                endMillis,
                storedElapsedSeconds,
                storedPausedDurationMillis,
                pausedFlag,
                storedPosition,
                recordedPositionUnit,
                insight,
                endMillis,
                now,
                input.recordId
            ]

            // SQL 目的：把停止待保存的阅读计时推进为完成记录，并写入结束确认补充信息。
            // 涉及表：read_time_record。
            // 关键过滤：id 精确命中、is_deleted = 0、status IN (0,1,2)，只允许未完成记录被保存。
            // 时间字段：end_time/interrupt_time/updated_date 为毫秒时间戳；elapsed_seconds 为秒，且必须排除暂停时长；paused 保留 Android“曾暂停过”语义；fuzzy_read_date 清零表示精确计时。
            // 副作用用途：status = 3 后记录进入首页、阅读日历、时间线和书架总时长统计。
            let sql = """
                UPDATE read_time_record
                SET status = ?,
                    book_id = ?,
                    start_time = ?,
                    end_time = ?,
                    elapsed_seconds = ?,
                    paused_duration_millis = ?,
                    paused = ?,
                    position = ?,
                    recorded_position_unit = ?,
                    insight = ?,
                    fuzzy_read_date = 0,
                    interrupt_time = ?,
                    updated_date = ?
                WHERE id = ?
                  AND is_deleted = 0
                  AND status IN (0, 1, 2)
            """
            try db.execute(sql: sql, arguments: arguments)
            let changedRows = try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
            guard changedRows > 0 else {
                throw ReadingTimerError.staleSessionState
            }

            if input.position != nil {
                try updateBookReadPositionIfNeeded(
                    db,
                    book: targetBook,
                    position: storedPosition,
                    updatedAt: now
                )
            }
            if input.markReadDone {
                try BookReadStatusMutation.updateBookReadStatus(
                    db,
                    bookID: targetBook.id,
                    statusID: BookEntryReadingStatus.finished.rawValue,
                    changedAt: endMillis,
                    updatedAt: now,
                    finishedRatingScore: nil
                )
            } else if targetBook.readStatusId != BookEntryReadingStatus.reading.rawValue {
                try BookReadStatusMutation.updateBookReadStatus(
                    db,
                    bookID: targetBook.id,
                    statusID: BookEntryReadingStatus.reading.rawValue,
                    changedAt: endMillis,
                    updatedAt: now,
                    finishedRatingScore: nil
                )
            }

            guard let session = try fetchSession(db, recordId: input.recordId),
                  session.status == .finished else {
                throw ReadingTimerError.sessionNotFound
            }
            return (session, try fetchActiveSession(db))
        }
        if let nextUnfinished = result.1 {
            syncAndroidPendingTimingRecordId(for: nextUnfinished)
        } else {
            AndroidSharedPreferencesCompat.clearPendingTimingRecordId(
                expectedRecordId: input.recordId,
                defaults: userDefaults
            )
        }
        return result.0
    }

    /// 软删除未完成计时记录，使放弃行为不进入统计且保持同步兼容。
    nonisolated func discardSession(recordId: Int64) async throws {
        let dbPool = await currentDatabasePool()
        let nextUnfinished = try await dbPool.write { db in
            let now = Self.currentTimestampMillis
            // SQL 目的：放弃未完成阅读计时，使用软删除保留同步语义并排除统计。
            // 涉及表：read_time_record。
            // 关键过滤：id 精确命中、is_deleted = 0、status IN (0,1,2)，避免删除已保存记录。
            // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
            // 副作用用途：App 关闭或用户主动放弃时不会静默产生统计数据。
            let sql = """
                UPDATE read_time_record
                SET is_deleted = 1,
                    updated_date = ?
                WHERE id = ?
                  AND is_deleted = 0
                  AND status IN (0, 1, 2)
                """
            try db.execute(sql: sql, arguments: [now, recordId])
            let changedRows = try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
            guard changedRows > 0 else {
                throw ReadingTimerError.staleSessionState
            }
            return try fetchActiveSession(db)
        }
        if let nextUnfinished {
            syncAndroidPendingTimingRecordId(for: nextUnfinished)
        } else {
            AndroidSharedPreferencesCompat.clearPendingTimingRecordId(
                expectedRecordId: recordId,
                defaults: userDefaults
            )
        }
    }

    /// 保存一条补录阅读记录，日期时长模式写 fuzzy_read_date，精确模式写 start_time/end_time。
    nonisolated func saveSupplement(_ input: ReadingTimerSupplementInput) async throws -> Int64 {
        guard input.elapsedSeconds > 0 else {
            throw ReadingTimerError.invalidDuration
        }

        let dbPool = await currentDatabasePool()
        return try await dbPool.write { db in
            guard let book = try fetchBookContext(db, bookId: input.bookId) else {
                throw ReadingTimerError.bookNotFound
            }

            let timing = try resolveSupplementTiming(input)
            let recordedPositionUnit: Int64?
            let storedPosition: Double
            if let position = input.position {
                try validateReadPosition(
                    position,
                    positionUnit: book.positionUnit,
                    totalPosition: book.totalPosition,
                    totalPagination: book.totalPagination
                )
                recordedPositionUnit = book.positionUnit
                storedPosition = position
            } else {
                recordedPositionUnit = nil
                storedPosition = 0
            }

            let now = Self.currentTimestampMillis
            var record = ReadTimeRecordRecord()
            record.bookId = input.bookId
            record.startTime = timing.startMillis
            record.endTime = timing.endMillis
            record.interruptTime = 0
            record.elapsedSeconds = timing.elapsedSeconds
            record.countdownSeconds = 0
            record.pausedDurationMillis = 0
            record.paused = 0
            record.position = storedPosition
            record.status = ReadingTimerRecordStatus.finished.rawValue
            record.fuzzyReadDate = timing.fuzzyReadDateMillis
            record.wereadReadDate = 0
            record.insight = Self.normalizedInsight(input.insight)
            record.recordedPositionUnit = recordedPositionUnit
            record.createdDate = now
            record.updatedDate = 0
            record.lastSyncDate = 0
            record.isDeleted = 0
            try record.insert(db)

            if input.position != nil {
                try updateBookReadPositionIfNeeded(
                    db,
                    book: book,
                    position: storedPosition,
                    updatedAt: now
                )
            }
            if input.markReadDone {
                try BookReadStatusMutation.updateBookReadStatus(
                    db,
                    bookID: book.id,
                    statusID: BookEntryReadingStatus.finished.rawValue,
                    changedAt: timing.statusChangedMillis,
                    updatedAt: now,
                    finishedRatingScore: nil
                )
            }

            guard let recordId = record.id else {
                throw ReadingTimerError.sessionNotFound
            }
            return recordId
        }
    }
}

private extension ReadingTimerRepository {
    /// 读取单本有效书籍上下文。
    nonisolated func fetchBookContext(_ db: Database, bookId: Int64) throws -> ReadingTimerBookContext? {
        // SQL 目的：读取阅读计时所需的书籍基础字段。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，排除占位书和已删除书籍。
        // 时间字段：不读取时间字段；进度字段用于结束保存时校验阅读位置。
        // 返回字段用途：构建计时页、结束确认 Sheet、补录页和 Live Activity 展示所需的书籍上下文。
        let sql = """
            SELECT id, name, author, cover, read_status_id, read_position,
                   total_position, total_pagination, current_position_unit, position_unit
            FROM book
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookId]) else {
            return nil
        }
        return mapBookContext(row)
    }

    /// 读取全局最新未完成计时。
    nonisolated func fetchActiveSession(_ db: Database) throws -> ReadingTimerSession? {
        // SQL 目的：读取全局最新未完成阅读计时，覆盖运行、暂停和停止待保存三类状态。
        // 涉及表：read_time_record r JOIN book b。
        // 关键过滤：r.is_deleted = 0、r.status IN (0,1,2)、r.book_id != 0、b.is_deleted = 0。
        // 时间字段：updated_date/created_date 为 Android 毫秒时间戳，用于恢复多条异常未完成记录时选择最新一条。
        // 返回字段用途：冷启动和回前台恢复 ReadingTimerSession。
        let sql = sessionSelectSQL + """

            WHERE r.is_deleted = 0
              AND r.status IN (0, 1, 2)
              AND r.book_id != 0
              AND b.is_deleted = 0
            ORDER BY CASE WHEN r.updated_date != 0 THEN r.updated_date ELSE r.created_date END DESC,
                     r.id DESC
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql) else { return nil }
        return try mapSession(row)
    }

    /// 按记录 ID 读取计时记录。
    nonisolated func fetchSession(_ db: Database, recordId: Int64) throws -> ReadingTimerSession? {
        // SQL 目的：按 read_time_record 主键读取单条计时记录及其书籍上下文。
        // 涉及表：read_time_record r JOIN book b。
        // 关键过滤：r.id = ?、r.is_deleted = 0、r.book_id != 0、b.is_deleted = 0。
        // 时间字段：start/end/interrupt/fuzzy/created/updated 均为 Android 毫秒时间戳，映射到 Date 仅供业务层展示和校准。
        // 返回字段用途：计时页刷新、结束保存后回读和补录验证。
        let sql = sessionSelectSQL + """

            WHERE r.id = ?
              AND r.is_deleted = 0
              AND r.book_id != 0
              AND b.is_deleted = 0
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [recordId]) else { return nil }
        return try mapSession(row)
    }

    nonisolated var sessionSelectSQL: String {
        """
        SELECT r.id AS record_id,
               r.book_id AS record_book_id,
               r.start_time,
               r.end_time,
               r.interrupt_time,
               r.elapsed_seconds,
               r.countdown_seconds,
               r.paused_duration_millis,
               r.paused,
               r.position,
               r.status,
               r.fuzzy_read_date,
               r.insight,
               r.recorded_position_unit,
               r.created_date AS record_created_date,
               r.updated_date AS record_updated_date,
               b.id AS book_id,
               b.name AS book_name,
               b.author AS book_author,
               b.cover AS book_cover,
               b.read_status_id,
               b.read_position,
               b.total_position,
               b.total_pagination,
               b.current_position_unit,
               b.position_unit
        FROM read_time_record r
        JOIN book b ON b.id = r.book_id
        """
    }

    /// 将书籍查询行映射为计时上下文。
    nonisolated func mapBookContext(_ row: Row) -> ReadingTimerBookContext {
        ReadingTimerBookContext(
            id: row["id"] ?? 0,
            name: row["name"] ?? "",
            author: row["author"] ?? "",
            coverURL: row["cover"] ?? "",
            readStatusId: row["read_status_id"] ?? 0,
            readPosition: row["read_position"] ?? 0,
            totalPosition: row["total_position"] ?? 0,
            totalPagination: row["total_pagination"] ?? 0,
            currentPositionUnit: row["current_position_unit"] ?? 0,
            positionUnit: row["position_unit"] ?? BookEntryProgressUnit.pagination.rawValue
        )
    }

    /// 将计时查询行映射为会话快照。
    nonisolated func mapSession(_ row: Row) throws -> ReadingTimerSession {
        let rawStatus: Int64 = row["status"] ?? 0
        guard let status = ReadingTimerRecordStatus(rawValue: rawStatus) else {
            throw ReadingTimerError.unsupportedStatus(rawStatus)
        }

        let book = ReadingTimerBookContext(
            id: row["book_id"] ?? 0,
            name: row["book_name"] ?? "",
            author: row["book_author"] ?? "",
            coverURL: row["book_cover"] ?? "",
            readStatusId: row["read_status_id"] ?? 0,
            readPosition: row["read_position"] ?? 0,
            totalPosition: row["total_position"] ?? 0,
            totalPagination: row["total_pagination"] ?? 0,
            currentPositionUnit: row["current_position_unit"] ?? 0,
            positionUnit: row["position_unit"] ?? BookEntryProgressUnit.pagination.rawValue
        )

        return ReadingTimerSession(
            id: row["record_id"] ?? 0,
            book: book,
            startTime: Self.date(fromMillis: row["start_time"] ?? 0),
            endTime: Self.date(fromMillis: row["end_time"] ?? 0),
            interruptTime: Self.date(fromMillis: row["interrupt_time"] ?? 0),
            elapsedSeconds: row["elapsed_seconds"] ?? 0,
            countdownSeconds: row["countdown_seconds"] ?? 0,
            pausedDurationMillis: row["paused_duration_millis"] ?? 0,
            isPaused: status == .paused,
            status: status,
            position: row["position"] ?? 0,
            recordedPositionUnit: row["recorded_position_unit"] as Int64?,
            fuzzyReadDate: Self.date(fromMillis: row["fuzzy_read_date"] ?? 0),
            insight: row["insight"] ?? "",
            createdDate: Self.date(fromMillis: row["record_created_date"] ?? 0),
            updatedDate: Self.date(fromMillis: row["record_updated_date"] ?? 0)
        )
    }

    /// 校验阅读位置，复用 Android 对齐的进度/位置/页码边界。
    nonisolated func validateReadPosition(
        _ readPosition: Double,
        positionUnit: Int64,
        totalPosition: Int64,
        totalPagination: Int64
    ) throws {
        if positionUnit == BookEntryProgressUnit.progress.rawValue, readPosition < 0 || readPosition > 100 {
            throw ReadingTimerError.invalidReadPosition("进度值应在 [0,100] 区间内")
        }
        if positionUnit == BookEntryProgressUnit.position.rawValue && totalPosition != 0 {
            if readPosition <= 0 {
                throw ReadingTimerError.invalidReadPosition("位置应大于 0")
            }
            if readPosition > Double(totalPosition) {
                throw ReadingTimerError.invalidReadPosition("位置应小于总位置（\(totalPosition)）")
            }
        }
        if positionUnit == BookEntryProgressUnit.pagination.rawValue && totalPagination != 0 {
            if readPosition <= 0 {
                throw ReadingTimerError.invalidReadPosition("页码应大于 0 页")
            }
            if readPosition > Double(totalPagination) {
                throw ReadingTimerError.invalidReadPosition("页码应小于总页码（\(totalPagination) 页）")
            }
        }
    }

    /// 根据本次阅读位置更新书籍当前进度；单位一致时取最大值，单位变化时切换到书籍默认单位。
    nonisolated func updateBookReadPositionIfNeeded(
        _ db: Database,
        book: ReadingTimerBookContext,
        position: Double,
        updatedAt: Int64
    ) throws {
        let targetPosition: Double
        if book.currentPositionUnit == book.positionUnit {
            targetPosition = max(book.readPosition, position)
        } else {
            targetPosition = position
        }

        // SQL 目的：保存阅读计时位置时同步 book 当前阅读位置。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，避免更新占位或已删除书籍。
        // 时间字段：updated_date 写入当前毫秒时间戳；阅读位置不涉及时区。
        // 副作用用途：让书籍详情、书架进度和后续书摘默认位置能感知本次阅读推进。
        let sql = """
            UPDATE book
            SET current_position_unit = position_unit,
                read_position = ?,
                updated_date = ?
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [targetPosition, updatedAt, book.id])
    }

    /// 解析补录输入为 Android 兼容的时间字段。
    nonisolated func resolveSupplementTiming(_ input: ReadingTimerSupplementInput) throws -> SupplementTiming {
        switch input.mode {
        case .dateDuration:
            guard let readDate = input.readDate, input.elapsedSeconds > 0 else {
                throw ReadingTimerError.invalidDuration
            }
            let dayStart = calendar.startOfDay(for: readDate)
            guard dayStart <= calendar.startOfDay(for: Date()) else {
                throw ReadingTimerError.invalidTimeRange
            }
            let dayStartMillis = Self.timestampMillis(from: dayStart)
            return SupplementTiming(
                startMillis: 0,
                endMillis: 0,
                fuzzyReadDateMillis: dayStartMillis,
                elapsedSeconds: input.elapsedSeconds,
                statusChangedMillis: dayStartMillis
            )
        case .timeRange:
            guard let startAt = input.startAt,
                  let endAt = input.endAt,
                  endAt > startAt,
                  endAt <= Date() else {
                throw ReadingTimerError.invalidTimeRange
            }
            let elapsedSeconds = max(1, Int64(endAt.timeIntervalSince(startAt)))
            let endMillis = Self.timestampMillis(from: endAt)
            return SupplementTiming(
                startMillis: Self.timestampMillis(from: startAt),
                endMillis: endMillis,
                fuzzyReadDateMillis: 0,
                elapsedSeconds: elapsedSeconds,
                statusChangedMillis: endMillis
            )
        }
    }

    /// 去掉首尾空白，避免表单输入的空感悟污染时间线展示。
    nonisolated static func normalizedInsight(_ insight: String) -> String {
        insight.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析 Android 语义的暂停历史标记，只要历史或本次快照出现暂停就保持为 1。
    nonisolated func resolvedPausedFlag(
        _ db: Database,
        recordId: Int64,
        incomingStatus: ReadingTimerRecordStatus,
        incomingPausedDurationMillis: Int64
    ) throws -> Int64 {
        // SQL 目的：读取当前计时记录的 paused 历史标记，避免继续或完成保存时把“曾暂停过”清零。
        // 涉及表：read_time_record。
        // 关键过滤：id 精确命中、is_deleted = 0，读取 Android 兼容字段 paused。
        // 返回字段用途：与本次状态和暂停累计时长合并，写回 Android 语义的暂停历史。
        let currentPaused = try Int64.fetchOne(
            db,
            sql: """
                SELECT paused
                FROM read_time_record
                WHERE id = ?
                  AND is_deleted = 0
                LIMIT 1
                """,
            arguments: [recordId]
        ) ?? 0
        return currentPaused != 0 || incomingStatus == .paused || incomingPausedDurationMillis > 0 ? 1 : 0
    }

    nonisolated static var currentTimestampMillis: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    nonisolated static func timestampMillis(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    nonisolated static func timestampMillis(from date: Date?) -> Int64? {
        date.map(timestampMillis(from:))
    }

    nonisolated static func date(fromMillis millis: Int64) -> Date? {
        guard millis > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    /// 同步 Android 冷启动恢复所依赖的 pending id；三种未完成状态均必须保留精确记录锚点。
    nonisolated func syncAndroidPendingTimingRecordId(for session: ReadingTimerSession) {
        switch session.status {
        case .running, .paused, .stoppedPendingSave:
            AndroidSharedPreferencesCompat.setPendingTimingRecordId(
                session.id,
                defaults: userDefaults
            )
        case .finished:
            AndroidSharedPreferencesCompat.clearPendingTimingRecordId(
                expectedRecordId: session.id,
                defaults: userDefaults
            )
        }
    }
}

private struct SupplementTiming {
    let startMillis: Int64
    let endMillis: Int64
    let fuzzyReadDateMillis: Int64
    let elapsedSeconds: Int64
    let statusChangedMillis: Int64
}
