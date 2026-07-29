/**
 * [INPUT]: 依赖 DesktopWebStatisticsRepository 的时间范围、阅读记录与完读事件能力，以及 V44 book/note/tag/source 关系表
 * [OUTPUT]: 提供 Android 七类 Statistics chart 接口与 overview 阅读趋势快照
 * [POS]: Data 层网页统计仓储图表扩展；保留日/月/年分桶、Float 精度和来源/标签资格口径
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated struct DesktopWebChartSnapshot: Sendable, Equatable {
    let unit: String
    let total: String
    let items: [DesktopWebStatisticsTrendSnapshot]
    let scope: String
    let scopeLabel: String
}

nonisolated struct DesktopWebPurchaseChartSnapshot: Sendable, Equatable {
    let unit: String
    let totalMoney: Float
    let totalCount: Int
    let items: [DesktopWebStatisticsTrendSnapshot]
    let countItems: [DesktopWebStatisticsTrendSnapshot]
    let scope: String
    let scopeLabel: String
}

nonisolated struct DesktopWebPieItemSnapshot: Sendable, Equatable {
    let label: String
    let count: Int
    let ratio: Float
    let scope: String
    let scopeLabel: String
}

nonisolated extension DesktopWebStatisticsRepository {
    struct TrendResult: Sendable, Equatable {
        let unit: String
        let items: [DesktopWebStatisticsTrendSnapshot]
    }

    /// 书摘创建时间柱状图；all 模式 total 包含 created_date=0 记录，但这些异常记录不进入分桶。
    func noteCountChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartSnapshot {
        let scope = try await timeScope(year: year, month: month, weekStart: weekStart)
        let bucket = try bucketSpec(scope: scope)
        let rows: [Int64] = try await database.dbPool.read { db in
            // SQL 目的：复刻 NoteDao.queryAll/queryInRange 的书摘图表输入。
            // 涉及表：note、book；仅统计仍存在书籍下的有效书摘。
            // 时间字段：范围模式按 created_date 毫秒闭区间筛选。
            // 返回字段用途：total 采用行数，created_date=0 在 all 图表分桶时被跳过。
            let condition = scope.isAll ? "" : " AND n.created_date BETWEEN ? AND ?"
            return try Int64.fetchAll(
                db,
                sql: """
                    SELECT n.created_date FROM note n JOIN book b ON b.id = n.book_id
                    WHERE n.is_deleted = 0 AND b.is_deleted = 0\(condition)
                    """,
                arguments: scope.isAll ? [] : [scope.start, scope.end]
            )
        }
        let values = bucketValues(bucket: bucket, timestamps: rows.filter { !scope.isAll || $0 != 0 }) { _ in 1 }
        return DesktopWebChartSnapshot(
            unit: bucket.unit,
            total: "\(rows.count)条",
            items: trendItems(values),
            scope: "NOTE_CREATED_TIME",
            scopeLabel: "书摘创建时间"
        )
    }

    /// 读完图表按 bookId 去重；all 模式同一本书可分别计入不同年份，范围模式只取范围内首次完读时间。
    func readDoneChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartSnapshot {
        let scope = try await timeScope(year: year, month: month, weekStart: weekStart)
        let bucket = try bucketSpec(scope: scope)
        let events = try await completedReadDoneEvents()
        var values = bucket.zeros
        if scope.isAll {
            let grouped = Dictionary(grouping: events, by: \.bookID)
            for timestamps in grouped.values {
                for label in Set(timestamps.map { bucket.label(for: $0.time, repository: self) }) {
                    values[label, default: 0] += 1
                }
            }
        } else {
            let scoped = events.filter { scope.start...scope.end ~= $0.time }
            let grouped = Dictionary(grouping: scoped, by: \.bookID)
            for events in grouped.values {
                guard let first = events.map(\.time).min() else { continue }
                values[bucket.label(for: first, repository: self), default: 0] += 1
            }
        }
        let items = trendItems(values)
        return DesktopWebChartSnapshot(
            unit: bucket.unit,
            total: scope.isAll ? "" : "\(items.reduce(0) { $0 + $1.value })本",
            items: items,
            scope: "READ_DONE_TIME",
            scopeLabel: "完读时间"
        )
    }

    /// 阅读字数图表只消费有效历史 READ_DONE 记录，并将每本书的正字数归到首次完读时间。
    func wordCountChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartSnapshot {
        let scope = try await timeScope(year: year, month: month, weekStart: weekStart)
        let bucket = try bucketSpec(scope: scope)
        let events = try await activeStatusEvents().filter { $0.status == 3 }
        let scopedEvents = scope.isAll ? events : events.filter { scope.start...scope.end ~= $0.time }
        let ids = Set(scopedEvents.map(\.bookID))
        let wordCounts = try await positiveWordCounts(bookIDs: ids)
        var values64 = Dictionary(uniqueKeysWithValues: bucket.zeros.keys.map { ($0, Int64(0)) })
        var total: Int64 = 0
        for (bookID, wordCount) in wordCounts {
            let bookEvents = scopedEvents.filter { $0.bookID == bookID }
            guard let first = bookEvents.map(\.time).min() else { continue }
            values64[bucket.label(for: first, repository: self), default: 0] += wordCount
            total += wordCount
        }
        let values = Dictionary(uniqueKeysWithValues: values64.map { key, value in
            (key, Int(Float(value)))
        })
        return DesktopWebChartSnapshot(
            unit: bucket.unit,
            total: formatWordCount(total),
            items: trendItems(values),
            scope: "READ_DONE_TIME",
            scopeLabel: "完读时间"
        )
    }

    /// 购入图表按 purchase_date 分桶，金额先以 Android Float 累加，再映射为整数趋势项。
    func purchaseChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebPurchaseChartSnapshot {
        let scope = try await timeScope(year: year, month: month, weekStart: weekStart)
        let bucket = try bucketSpec(scope: scope)
        let rows: [(time: Int64, price: Float)] = try await database.dbPool.read { db in
            // SQL 目的：复刻 queryAllPurchaseBooks/queryPurchaseBooksInRange 的购入图表输入。
            // 涉及表：book；过滤有效非占位、price>0、purchase_date!=0。
            // 时间字段：范围模式按 purchase_date 毫秒闭区间筛选。
            // 返回字段用途：按桶分别累计 Float 金额和书籍数量。
            let condition = scope.isAll ? "" : " AND purchase_date BETWEEN ? AND ?"
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT purchase_date, price FROM book
                    WHERE is_deleted = 0 AND id != 0 AND price > 0 AND purchase_date != 0\(condition)
                    """,
                arguments: scope.isAll ? [] : [scope.start, scope.end]
            ).map { ($0["purchase_date"], Float($0["price"] as Double)) }
        }
        var money = Dictionary(uniqueKeysWithValues: bucket.zeros.keys.map { ($0, Float(0)) })
        var counts = bucket.zeros
        for row in rows {
            let label = bucket.label(for: row.time, repository: self)
            money[label, default: 0] += row.price
            counts[label, default: 0] += 1
        }
        let moneyItems = trendItems(Dictionary(uniqueKeysWithValues: money.map { ($0.key, Int($0.value)) }))
        let countItems = trendItems(counts)
        let totalMoney = Float(money.values.reduce(0.0) { $0 + Double($1) })
        return DesktopWebPurchaseChartSnapshot(
            unit: bucket.unit,
            totalMoney: totalMoney,
            totalCount: counts.values.reduce(0, +),
            items: moneyItems,
            countItems: countItems,
            scope: "PURCHASE_TIME",
            scopeLabel: "购入时间"
        )
    }

    /// 书籍来源饼图使用历史目标状态资格集；未知或已删除来源统一汇入“未知”。
    func bookSourceChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItemSnapshot] {
        let scope = try await timeScope(year: year, month: month, weekStart: weekStart)
        let ids = try await eligibleBookIDs(scope: scope)
        guard !ids.isEmpty else { return [] }
        return try await database.dbPool.read { db in
            // SQL 目的：复刻来源主表顺序及资格书籍 source_id 聚合。
            // 涉及表：source、book；source 不按 owner 过滤，book 必须有效且在资格 ID 集合。
            // 返回字段用途：已知来源按 source_order 输出，无法命中有效来源的书籍汇总为“未知”。
            let sources = try Row.fetchAll(
                db,
                sql: "SELECT id, name FROM source WHERE is_deleted = 0 ORDER BY source_order ASC"
            ).map { (id: $0["id"] as Int64, name: $0["name"] as String) }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT source_id, COUNT(*) AS value FROM book
                    WHERE id IN (\(placeholders)) AND is_deleted = 0 AND id != 0
                    GROUP BY source_id
                    """,
                arguments: StatementArguments(Array(ids))
            )
            let counts = Dictionary(uniqueKeysWithValues: rows.map {
                ($0["source_id"] as Int64, Int($0["value"] as Int64))
            })
            let knownIDs = Set(sources.map(\.id))
            let unknown = counts.filter { !knownIDs.contains($0.key) }.values.reduce(0, +)
            let total = counts.values.reduce(0, +)
            guard total > 0 else { return [] }
            var result = sources.compactMap { source -> DesktopWebPieItemSnapshot? in
                guard let count = counts[source.id], count > 0 else { return nil }
                return .init(
                    label: source.name, count: count, ratio: Float(count) / Float(total),
                    scope: "BOOK_PROGRESS", scopeLabel: "阅读进展（想读/在读/已读/搁置）"
                )
            }
            if unknown > 0 {
                result.append(
                    .init(
                        label: "未知", count: unknown, ratio: Float(unknown) / Float(total),
                        scope: "BOOK_PROGRESS", scopeLabel: "阅读进展（想读/在读/已读/搁置）"
                    )
                )
            }
            return result
        }
    }

    /// 书摘标签饼图保留 Android all 模式只看 tag_note 删除态、范围模式再校验 note 的不对称语义。
    func noteTagChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItemSnapshot] {
        // NOTE(ANDROID-WEB-058): all 模式只校验 tag_note 墓碑，已删除 note 的遗留关系仍被计数。
        let scope = try await timeScope(year: year, month: month, weekStart: weekStart)
        return try await database.dbPool.read { db in
            // SQL 目的：读取 owner=1、type=1 的有效书摘标签及每标签关系数。
            // 涉及表：tag、tag_note；范围模式额外连接 note 并过滤 note.is_deleted/created_date。
            // 关键差异：all 模式故意不校验 note 主记录删除态，对齐 TagDao.queryNoteCountOfTag。
            // 返回字段用途：按 tag_order 输出 NOTE_CREATED_TIME 饼图。
            let tags = try Row.fetchAll(
                db,
                sql: "SELECT id, name FROM tag WHERE user_id = 1 AND type = 1 AND is_deleted = 0 ORDER BY tag_order ASC"
            ).map { (id: $0["id"] as Int64, name: $0["name"] as String) }
            var counts: [Int64: Int] = [:]
            for tag in tags {
                let count: Int
                if scope.isAll {
                    count = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM tag_note WHERE tag_id = ? AND is_deleted = 0",
                        arguments: [tag.id]
                    ) ?? 0
                } else {
                    count = try Int.fetchOne(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM tag_note tn JOIN note n ON n.id = tn.note_id
                            WHERE tn.tag_id = ? AND tn.is_deleted = 0 AND n.is_deleted = 0
                              AND n.created_date BETWEEN ? AND ?
                            """,
                        arguments: [tag.id, scope.start, scope.end]
                    ) ?? 0
                }
                counts[tag.id] = count
            }
            let total = counts.values.reduce(0, +)
            guard total > 0 else { return [] }
            return tags.compactMap { tag in
                guard let count = counts[tag.id], count > 0 else { return nil }
                return .init(
                    label: tag.name, count: count, ratio: Float(count) / Float(total),
                    scope: "NOTE_CREATED_TIME", scopeLabel: "书摘创建时间"
                )
            }
        }
    }

    /// 书籍标签饼图使用与来源相同的状态资格书籍，并按有效标签顺序统计去重书籍数。
    func bookTagChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItemSnapshot] {
        let scope = try await timeScope(year: year, month: month, weekStart: weekStart)
        let ids = try await eligibleBookIDs(scope: scope)
        guard !ids.isEmpty else { return [] }
        return try await database.dbPool.read { db in
            // SQL 目的：读取 owner=1、type=2 的有效书籍标签并统计资格书籍关系。
            // 涉及表：tag、tag_book、book；关系和书籍必须有效，每标签按 book_id 去重。
            // 返回字段用途：按 tag_order 输出 BOOK_PROGRESS 饼图。
            let tags = try Row.fetchAll(
                db,
                sql: "SELECT id, name FROM tag WHERE user_id = 1 AND type = 2 AND is_deleted = 0 ORDER BY tag_order ASC"
            ).map { (id: $0["id"] as Int64, name: $0["name"] as String) }
            guard !tags.isEmpty else { return [] }
            let tagPlaceholders = Array(repeating: "?", count: tags.count).joined(separator: ",")
            let bookPlaceholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let arguments = StatementArguments(tags.map(\.id) + Array(ids))
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT tb.tag_id, COUNT(DISTINCT tb.book_id) AS value
                    FROM tag_book tb JOIN book b ON b.id = tb.book_id
                    WHERE tb.tag_id IN (\(tagPlaceholders)) AND tb.book_id IN (\(bookPlaceholders))
                      AND tb.is_deleted = 0 AND b.is_deleted = 0
                    GROUP BY tb.tag_id
                    """,
                arguments: arguments
            )
            let counts = Dictionary(uniqueKeysWithValues: rows.map {
                ($0["tag_id"] as Int64, Int($0["value"] as Int64))
            })
            let total = counts.values.reduce(0, +)
            guard total > 0 else { return [] }
            return tags.compactMap { tag in
                guard let count = counts[tag.id], count > 0 else { return nil }
                return .init(
                    label: tag.name, count: count, ratio: Float(count) / Float(total),
                    scope: "BOOK_PROGRESS", scopeLabel: "阅读进展（想读/在读/已读/搁置）"
                )
            }
        }
    }

    /// 为 overview 生成阅读时长趋势，保持与独立图表相同的跨日拆分和分桶规则。
    func readingTimeTrend(scope: TimeScope) async throws -> TrendResult {
        let bucket = try bucketSpec(scope: scope)
        let records = try await readRecords()
        let scoped = scope.isAll ? records : records.filter { scope.start...scope.end ~= $0.eventTime }
        var values64 = Dictionary(uniqueKeysWithValues: bucket.zeros.keys.map { ($0, Int64(0)) })
        for record in scoped {
            values64[bucket.label(for: record.eventTime, repository: self), default: 0] += record.elapsedSeconds
        }
        let values = Dictionary(uniqueKeysWithValues: values64.map { ($0.key, Int(Float($0.value))) })
        return TrendResult(unit: bucket.unit, items: trendItems(values))
    }
}

private nonisolated extension DesktopWebStatisticsRepository {
    struct BucketSpec: Sendable {
        enum Kind: Sendable { case year, month, day }
        let kind: Kind
        let unit: String
        let zeros: [Int: Int]

        func label(for timestamp: Int64, repository: DesktopWebStatisticsRepository) -> Int {
            switch kind {
            case .year: repository.dateComponent(.year, millis: timestamp)
            case .month: repository.dateComponent(.month, millis: timestamp)
            case .day: repository.dateComponent(.day, millis: timestamp)
            }
        }
    }

    func bucketSpec(scope: TimeScope) throws -> BucketSpec {
        let startYear = dateComponent(.year, millis: scope.start)
        let endYear = dateComponent(.year, millis: scope.end)
        let startMonth = dateComponent(.month, millis: scope.start)
        let endMonth = dateComponent(.month, millis: scope.end)
        if scope.isAll {
            let years = startYear <= endYear ? Array(startYear...endYear) : []
            return BucketSpec(kind: .year, unit: "年", zeros: Dictionary(uniqueKeysWithValues: years.map { ($0, 0) }))
        }
        if scope.end >= scope.start, scope.end - scope.start <= 7 * 86_400_000 {
            let start = Date(timeIntervalSince1970: Double(scope.start) / 1_000)
            let labels = (0..<7).compactMap {
                calendar.date(byAdding: .day, value: $0, to: start)
            }.map { calendar.component(.day, from: $0) }
            return BucketSpec(
                kind: .day,
                unit: "日",
                zeros: Dictionary(uniqueKeysWithValues: labels.map { ($0, 0) })
            )
        }
        if startMonth == endMonth {
            guard let date = calendar.date(from: DateComponents(year: startYear, month: startMonth, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: date) else {
                throw DesktopWebStatisticsRepositoryError.invalidDate
            }
            return BucketSpec(kind: .day, unit: "日", zeros: Dictionary(uniqueKeysWithValues: days.map { ($0, 0) }))
        }
        return BucketSpec(kind: .month, unit: "月", zeros: Dictionary(uniqueKeysWithValues: (1...12).map { ($0, 0) }))
    }

    func bucketValues(
        bucket: BucketSpec,
        timestamps: [Int64],
        value: (Int64) -> Int
    ) -> [Int: Int] {
        var result = bucket.zeros
        for timestamp in timestamps {
            result[bucket.label(for: timestamp, repository: self), default: 0] += value(timestamp)
        }
        return result
    }

    func trendItems(_ values: [Int: Int]) -> [DesktopWebStatisticsTrendSnapshot] {
        values.keys.sorted().map { .init(label: $0, value: values[$0] ?? 0) }
    }

    func positiveWordCounts(bookIDs: Set<Int64>) async throws -> [Int64: Int64] {
        guard !bookIDs.isEmpty else { return [:] }
        return try await database.dbPool.read { db in
            // SQL 目的：批量读取有效书籍的正 word_count。
            // 涉及表：book；ID 来自历史 READ_DONE 状态，排除删除书籍与零/空字数。
            // 返回字段用途：阅读字数图表按首次完读时间归桶。
            let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, word_count FROM book WHERE is_deleted = 0 AND id IN (\(placeholders)) AND word_count > 0",
                arguments: StatementArguments(Array(bookIDs))
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["word_count"] as Int64) })
        }
    }

    func eligibleBookIDs(scope: TimeScope) async throws -> Set<Int64> {
        try await database.dbPool.read { db in
            // SQL 目的：复刻 queryEligibleBookIdsForSourceAndTag 的历史状态与无历史快照兜底。
            // 涉及表：book_read_status_record、book；资格状态为想读/在读/读完/搁置（1,2,3,5）。
            // 关键过滤：历史分支不预先校验书籍删除态，后续来源/标签聚合再过滤；范围为 changed_date 闭区间。
            // 返回字段用途：来源与书籍标签饼图的资格书籍集合。
            let historyCondition = scope.isAll ? "" : " AND changed_date BETWEEN ? AND ?"
            let historyArgs: StatementArguments = scope.isAll ? [] : [scope.start, scope.end]
            let history = try Int64.fetchAll(
                db,
                sql: """
                    SELECT book_id FROM book_read_status_record
                    WHERE is_deleted = 0 AND book_id != 0 AND changed_date != 0
                      AND read_status_id IN (1, 2, 3, 5)\(historyCondition)
                    GROUP BY book_id
                    """,
                arguments: historyArgs
            )
            let fallbackCondition = scope.isAll ? "" : " AND b.read_status_changed_date BETWEEN ? AND ?"
            let fallbackArgs: StatementArguments = scope.isAll ? [] : [scope.start, scope.end]
            let fallback = try Int64.fetchAll(
                db,
                sql: """
                    SELECT b.id FROM book b
                    WHERE b.id != 0 AND b.is_deleted = 0 AND b.read_status_id IN (1, 2, 3, 5)
                      \(fallbackCondition)
                      AND NOT EXISTS (
                          SELECT 1 FROM book_read_status_record r
                          WHERE r.book_id = b.id AND r.is_deleted = 0
                      )
                    """,
                arguments: fallbackArgs
            )
            return Set(history + fallback)
        }
    }

    func formatWordCount(_ count: Int64) -> String {
        if count >= 10_000 { return String(format: "%.1f万字", Double(count) / 10_000) }
        if count >= 1_000 { return String(format: "%.1f千字", Double(count) / 1_000) }
        return "\(count)字"
    }
}
