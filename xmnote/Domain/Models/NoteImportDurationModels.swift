/**
 * [INPUT]: 依赖不可变导入来源与 Foundation 日期运算
 * [OUTPUT]: 提供时长策略、纯合并计算、评估快照及同目标提交契约
 * [POS]: Domain/Models 的导入私有时长语义，不访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// 用户为一个目标书籍明确选择的时长处理方式。
nonisolated enum NoteImportDurationPolicy: String, CaseIterable, Codable, Sendable {
    case merge, replace, keep
    var title: String {
        switch self { case .merge: "合并导入"; case .replace: "替换本地时长"; case .keep: "保留本地时长" }
    }
    var summary: String {
        switch self { case .merge: "时长合并导入"; case .replace: "时长替换本地"; case .keep: "时长保留本地" }
    }
}

/// 只表达来源总时长，不把缺失字段当作零。
nonisolated enum NoteImportDurationFilter: String, CaseIterable, Codable, Sendable {
    case all, upToThirty, overThirty, missing
    var title: String {
        switch self { case .all: "全部"; case .upToThirty: "30 分钟及以内"; case .overThirty: "超过 30 分钟"; case .missing: "未提供" }
    }
    /// 秒级比较保证恰好三十分钟仅属于一个区间。
    func matches(_ seconds: Int64?) -> Bool {
        switch self {
        case .all: true
        case .upToThirty: seconds.map { $0 <= 1800 } ?? false
        case .overThirty: seconds.map { $0 > 1800 } ?? false
        case .missing: seconds == nil
        }
    }
}

/// 纯计算需要的记录字段；本地身份用于保持已有记录及其附属信息。
nonisolated struct NoteImportDurationEntry: Equatable, Sendable {
    var id: Int64?
    var start: Int64 = 0
    var end: Int64 = 0
    var day: Int64 = 0
    var wereadDay: Int64 = 0
    var seconds: Int64 = 0
    var position: Double = 0
    var status: Int64 = 3
}

/// 评估和实际落库共用的纯运算，保留来源顺序和既有日期合并语义。
nonisolated enum NoteImportDurationMerge {
    /// 对传入副本计算结果，不改写来源，也不尝试猜测跨来源重叠。
    static func apply(_ drafts: [NoteImportDraftBook], to original: [NoteImportDurationEntry]) -> [NoteImportDurationEntry] {
        var records = original
        for draft in drafts {
            for item in draft.wereadReadingDurations ?? [] {
                guard let day = item.date, day > 0, let seconds = item.durationSeconds, seconds > 0 else { continue }
                if let index = records.firstIndex(where: { $0.wereadDay == day }) {
                    records[index].seconds = seconds
                } else {
                    records.append(.init(day: day, wereadDay: day, seconds: seconds))
                }
            }
            for item in draft.preciseReadingDurations ?? [] {
                guard let start = item.startTime, let end = item.endTime, start > 0, end > start else { continue }
                guard !records.contains(where: { $0.start == start && $0.end == end }) else { continue }
                records.append(.init(start: start, end: end, seconds: Int64((Double(end - start) / 1000).rounded()), position: item.position ?? 0))
            }
            for item in draft.fuzzyReadingDurations ?? [] {
                guard let day = item.date, day > 0, let seconds = item.durationSeconds, seconds > 0 else { continue }
                let calendar = Calendar.current
                let startDate = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(day) / 1000))
                let start = Int64(startDate.timeIntervalSince1970 * 1000)
                let end = Int64((calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate).timeIntervalSince1970 * 1000)
                let indices = records.indices.filter { index in
                    let record = records[index]
                    return record.status == 3 && ((record.start >= start && record.start < end) || (record.day >= start && record.day < end))
                }
                let local = indices.reduce(Int64(0)) { $0 + records[$1].seconds }
                guard seconds > local else { continue }
                if let index = indices.last(where: { records[$0].day != 0 }) {
                    records[index].seconds += seconds - local
                    records[index].position = item.position ?? 0
                } else {
                    records.append(.init(day: day, seconds: seconds - local, position: item.position ?? 0))
                }
            }
        }
        return records
    }
    /// 来源在空书上的规范化总额，用于筛选和来源摘要。
    static func sourceSeconds(_ drafts: [NoteImportDraftBook]) -> Int64? {
        let records = apply(drafts, to: [])
        return records.isEmpty ? nil : total(records)
    }
    /// 只统计完成记录，未结束计时另行阻止替换。
    static func total(_ entries: [NoteImportDurationEntry]) -> Int64 {
        entries.filter { $0.status == 3 }.reduce(0) { $0 + $1.seconds }
    }
    /// 秒精度展示，不把不足一分钟的来源误报为没有时长。
    static func text(_ seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, rest = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) 小时") }
        if minutes > 0 { parts.append("\(minutes) 分钟") }
        if rest > 0 { parts.append("\(rest) 秒") }
        return parts.joined(separator: " ")
    }
}

/// 本地全记录快照绑定用户决定，任何记录或附属资料变化都会令提交失效。
nonisolated struct NoteImportDurationAssessment: Equatable, Sendable {
    var snapshot: Data
    var localCount: Int
    var localSeconds: Int64
    var sourceSeconds: Int64?
    var mergedSeconds: Int64
    var hasActiveTimer: Bool
    var insightCount: Int
    var positionCount: Int
    var needsDecision: Bool { localCount > 0 && sourceSeconds != nil }
    /// 预估来自与写入相同的运算，不直接相加两个汇总值。
    func resultSeconds(for policy: NoteImportDurationPolicy) -> Int64 {
        switch policy { case .merge: mergedSeconds; case .replace: sourceSeconds ?? 0; case .keep: localSeconds }
    }
}

/// 一个目标只清空一次并共享资料，来源身份用于组级重试与结果展示。
nonisolated struct NoteImportCommitGroup: Sendable {
    var sourceIDs: [UUID]
    var books: [NoteImportCommitBook]
    var policy: NoteImportDurationPolicy
    var assessment: NoteImportDurationAssessment?
}

/// 仅在整个目标事务成功后产生，取消不会撤销已经返回的结果。
nonisolated struct NoteImportCommitGroupResult: Identifiable, Sendable {
    var id: Int64 { targetID }
    var targetID: Int64
    var sourceIDs: [UUID]
    var title: String
    var policy: NoteImportDurationPolicy
    var finalSeconds: Int64
    var includesDuration: Bool
}

/// 可恢复的时长决策错误，调用方重新评估后保留内容草稿。
nonisolated enum NoteImportDurationError: LocalizedError {
    case changed, activeTimer, missingSource, unavailable
    var errorDescription: String? {
        switch self {
        case .changed: "本地阅读记录已变化，请重新选择时长处理方式"
        case .activeTimer: "本书还有未完成的计时，请先处理计时再替换"
        case .missingSource: "没有可导入的阅读时长，无法替换本地记录"
        case .unavailable: "当前仓储不支持时长评估或同书提交"
        }
    }
}
