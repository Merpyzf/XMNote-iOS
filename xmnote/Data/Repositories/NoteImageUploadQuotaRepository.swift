/**
 * [INPUT]: 依赖 S3ConfigRepositoryProtocol 判断当前图床，依赖 AppBackendConfigRepositoryProtocol 获取动态日上限，依赖 UserDefaults 单体持久化日账本
 * [OUTPUT]: 对外提供 NoteImageUploadQuotaRepository，统一实现每日新增图片限额、跨编辑器原子预占、幂等提交与孤儿票据整理
 * [POS]: Data 层图片额度仓储，是书摘、书评与相关内容编辑器申请、释放和提交图片额度的唯一入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android 业务规则对齐的图片日限额仓储；Actor 保证多个编辑器不会同时消费同一份余额。
actor NoteImageUploadQuotaRepository: NoteImageUploadQuotaRepositoryProtocol {
    nonisolated private static let defaultDailyLimit = 20
    nonisolated private static let dailyLimitConfigKey = "NOTE_IMAGE_UPLOAD_LIMIT"
    nonisolated private static let ledgerStorageKey = "note_image_quota_ledger_v2"
    nonisolated private static let legacySavedCountKeyPrefix = "note_image_saved_count_"

    private let configRepository: any S3ConfigRepositoryProtocol
    private let appBackendConfigRepository: any AppBackendConfigRepositoryProtocol
    private let userDefaults: UserDefaults
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private var hasLoadedLedger = false
    private var ledger: NoteImageUploadDailyLedger?
    private var commitInFlightReservationIDs = Set<String>()

    /// 注入配置、持久化和时钟依赖；所有异步配置读取结束后，额度账本仍只在 Actor 内同步变更。
    init(
        configRepository: any S3ConfigRepositoryProtocol,
        appBackendConfigRepository: any AppBackendConfigRepositoryProtocol,
        userDefaults: UserDefaults = .standard,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configRepository = configRepository
        self.appBackendConfigRepository = appBackendConfigRepository
        self.userDefaults = userDefaults
        self.calendar = calendar
        self.now = now
    }

    /// 对齐草稿实际新图数；配置等待期间 Actor 可重入，但 in-flight commit 会阻断同 ticket 改写，调用取消不会留下半转换。
    func reconcileReservation(
        id: String,
        owner: NoteImageUploadReservationOwner,
        draftNewImageCount: Int,
        isPersistedDraft: Bool,
        isPremium: Bool
    ) async -> NoteImageUploadQuotaState {
        let context = await limitContext(isPremium: isPremium)
        let bucket = currentDateBucket()
        prepareLedger(for: bucket)
        let normalizedCount = max(0, draftNewImageCount)

        guard var ledger else {
            return .empty(context: context)
        }
        guard !commitInFlightReservationIDs.contains(id) else {
            return makeState(
                context: context,
                reservationID: id,
                unlimitedDraftCount: normalizedCount,
                ledger: ledger
            )
        }
        if ledger.committedReservationIDs[id] == nil, normalizedCount > 0 {
            let existing = ledger.reservations[id]
            ledger.reservations[id] = NoteImageUploadStoredReservation(
                id: id,
                owner: owner,
                dateBucket: bucket,
                count: normalizedCount,
                updatedAt: now(),
                isOwnerConfirmed: isPersistedDraft
                    || (existing?.owner == owner && existing?.isOwnerConfirmed == true)
            )
        } else {
            ledger.reservations[id] = nil
        }
        if isPersistedDraft {
            removeSiblingReservations(of: owner, keeping: id, from: &ledger)
        }
        self.ledger = ledger
        persistLedger()
        return makeState(
            context: context,
            reservationID: id,
            unlimitedDraftCount: normalizedCount,
            ledger: ledger
        )
    }

    /// 先对齐调用方现有草稿数，再原子接纳本次选择；配置等待结束后重新进入 Actor 串行修改账本。
    func reserveImages(
        id: String,
        owner: NoteImageUploadReservationOwner,
        currentDraftNewImageCount: Int,
        requestedCount: Int,
        isPremium: Bool
    ) async -> NoteImageUploadReservationResult {
        let context = await limitContext(isPremium: isPremium)
        let bucket = currentDateBucket()
        prepareLedger(for: bucket)
        guard var ledger else {
            return NoteImageUploadReservationResult(
                acceptedCount: 0,
                state: .empty(context: context)
            )
        }
        guard !commitInFlightReservationIDs.contains(id) else {
            return NoteImageUploadReservationResult(
                acceptedCount: 0,
                state: makeState(
                    context: context,
                    reservationID: id,
                    unlimitedDraftCount: currentDraftNewImageCount,
                    ledger: ledger
                )
            )
        }
        guard ledger.committedReservationIDs[id] == nil else {
            return NoteImageUploadReservationResult(
                acceptedCount: 0,
                state: makeState(
                    context: context,
                    reservationID: id,
                    unlimitedDraftCount: currentDraftNewImageCount,
                    ledger: ledger
                )
            )
        }
        let existing = ledger.reservations[id]
        let normalizedCurrentCount = max(
            max(0, currentDraftNewImageCount),
            existing?.count ?? 0
        )
        let normalizedRequestedCount = max(0, requestedCount)
        if normalizedCurrentCount > 0 {
            ledger.reservations[id] = NoteImageUploadStoredReservation(
                id: id,
                owner: owner,
                dateBucket: bucket,
                count: normalizedCurrentCount,
                updatedAt: now(),
                isOwnerConfirmed: existing?.owner == owner
                    && existing?.isOwnerConfirmed == true
            )
        } else {
            ledger.reservations[id] = nil
        }
        let acceptedCount: Int
        if context.isLimited {
            let availableCount = max(
                0,
                context.dailyLimit - ledger.savedCount - totalReservedCount(in: ledger)
            )
            acceptedCount = min(normalizedRequestedCount, availableCount)
        } else {
            acceptedCount = normalizedRequestedCount
        }
        let finalCount = normalizedCurrentCount + acceptedCount
        if finalCount > 0 {
            ledger.reservations[id] = NoteImageUploadStoredReservation(
                id: id,
                owner: owner,
                dateBucket: bucket,
                count: finalCount,
                updatedAt: now(),
                isOwnerConfirmed: existing?.owner == owner
                    && existing?.isOwnerConfirmed == true
            )
        }
        self.ledger = ledger
        persistLedger()
        return NoteImageUploadReservationResult(
            acceptedCount: acceptedCount,
            state: makeState(
                context: context,
                reservationID: id,
                unlimitedDraftCount: finalCount,
                ledger: ledger
            )
        )
    }

    /// 明确丢弃时移除 ticket；当天其他编辑器可立即使用释放的余额。
    func releaseReservation(id: String) async {
        guard !commitInFlightReservationIDs.contains(id) else { return }
        prepareLedger(for: currentDateBucket())
        guard var ledger, ledger.reservations.removeValue(forKey: id) != nil else { return }
        self.ledger = ledger
        persistLedger()
    }

    /// 主内容成功后重新核验会员与图床；等待期间锁定同 ticket，随后以单次 ledger 写入完成幂等转换。
    func commitReservation(id: String, savedImageCount: Int, isPremium: Bool) async {
        let claimedBucket = currentDateBucket()
        prepareLedger(for: claimedBucket)
        guard !commitInFlightReservationIDs.contains(id),
              let claimedLedger = ledger,
              claimedLedger.committedReservationIDs[id] == nil,
              let claimedReservation = claimedLedger.reservations[id] else {
            return
        }
        commitInFlightReservationIDs.insert(id)
        defer { commitInFlightReservationIDs.remove(id) }

        let context = await limitContext(isPremium: isPremium)
        let commitBucket = currentDateBucket()
        prepareLedger(for: commitBucket)
        guard var ledger, ledger.committedReservationIDs[id] == nil else { return }
        let reservation: NoteImageUploadStoredReservation
        if commitBucket == claimedBucket {
            guard let currentReservation = ledger.reservations.removeValue(forKey: id) else { return }
            reservation = currentReservation
        } else {
            ledger.reservations[id] = nil
            reservation = claimedReservation
        }

        if context.isLimited {
            let committedCount = min(max(0, savedImageCount), reservation.count)
            ledger.savedCount += committedCount
        }
        ledger.committedReservationIDs[id] = now()
        self.ledger = ledger
        persistLedger()
    }
}

private extension NoteImageUploadQuotaRepository {
    /// 动态上限解析遵循 Android：缺失或非法回退 20，合法负数归零；配置失败不阻断编辑。
    func limitContext(isPremium: Bool) async -> NoteImageUploadLimitContext {
        async let remoteLimitValue = appBackendConfigRepository.queryValue(
            key: Self.dailyLimitConfigKey
        )
        let isUsingBundledDefault: Bool
        if isPremium {
            isUsingBundledDefault = false
        } else {
            isUsingBundledDefault = await isUsingBundledDefaultConfiguration()
        }
        let fetchedRemoteLimitValue = await remoteLimitValue
        let rawLimit = fetchedRemoteLimitValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dailyLimit = rawLimit.flatMap(Int.init).map { max(0, $0) }
            ?? Self.defaultDailyLimit
        return NoteImageUploadLimitContext(
            isLimited: !isPremium && isUsingBundledDefault,
            dailyLimit: dailyLimit
        )
    }

    /// 当前配置读取异常或未命中时按 Android currentCosId <= 0 的语义回退为默认图床。
    func isUsingBundledDefaultConfiguration() async -> Bool {
        do {
            return try await configRepository.fetchCurrentConfig()?.isBundledDefault ?? true
        } catch {
            return true
        }
    }

    /// 生成调用方快照；remainingCount 已扣除所有活跃 ticket，而非只扣当前草稿。
    func makeState(
        context: NoteImageUploadLimitContext,
        reservationID: String,
        unlimitedDraftCount: Int,
        ledger: NoteImageUploadDailyLedger
    ) -> NoteImageUploadQuotaState {
        let ownCount = ledger.reservations[reservationID]?.count
            ?? (context.isLimited ? 0 : max(0, unlimitedDraftCount))
        let remainingCount = context.isLimited
            ? max(0, context.dailyLimit - ledger.savedCount - totalReservedCount(in: ledger))
            : Int.max
        return NoteImageUploadQuotaState(
            isLimited: context.isLimited,
            dailyLimit: context.dailyLimit,
            todaySavedCount: ledger.savedCount,
            currentDraftNewImageCount: ownCount,
            remainingCount: remainingCount
        )
    }

    /// 使用用户当前日历与时区生成稳定的 YYYY-MM-DD 桶，不依赖 UTC 日期。
    func currentDateBucket() -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: now())
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// 首次访问恢复当天单体账本；跨进程未确认票据与同 owner 旧票据会被清除，避免崩溃窗口永久占额。
    func prepareLedger(for bucket: String) {
        if !hasLoadedLedger {
            hasLoadedLedger = true
            let decoded = userDefaults.data(forKey: Self.ledgerStorageKey).flatMap {
                try? JSONDecoder().decode(NoteImageUploadDailyLedger.self, from: $0)
            }
            if var decoded {
                reconcilePersistedReservations(in: &decoded)
                if decoded.dateBucket == bucket {
                    ledger = decoded
                } else {
                    ledger = rolledLedger(
                        from: decoded,
                        to: bucket,
                        savedCount: legacySavedCount(for: bucket)
                    )
                }
            } else {
                ledger = NoteImageUploadDailyLedger(
                    dateBucket: bucket,
                    savedCount: legacySavedCount(for: bucket),
                    reservations: [:],
                    committedReservationIDs: [:]
                )
            }
            persistLedger()
            return
        }

        guard ledger?.dateBucket != bucket else { return }
        if let ledger {
            self.ledger = rolledLedger(from: ledger, to: bucket, savedCount: 0)
        }
        persistLedger()
    }

    /// 自然日切换时清零已保存数和提交标记，但把仍未保存的草稿票据迁入新日桶，保证跨午夜保存仍有真实 ticket。
    func rolledLedger(
        from source: NoteImageUploadDailyLedger,
        to bucket: String,
        savedCount: Int
    ) -> NoteImageUploadDailyLedger {
        let rolledReservations = source.reservations.values.map { reservation in
            NoteImageUploadStoredReservation(
                id: reservation.id,
                owner: reservation.owner,
                dateBucket: bucket,
                count: reservation.count,
                updatedAt: now(),
                isOwnerConfirmed: reservation.isOwnerConfirmed
            )
        }
        return NoteImageUploadDailyLedger(
            dateBucket: bucket,
            savedCount: max(0, savedCount),
            reservations: Dictionary(
                uniqueKeysWithValues: rolledReservations.map { ($0.id, $0) }
            ),
            committedReservationIDs: source.committedReservationIDs
        )
    }

    /// 启动时只信任已写入自动草稿的票据；同一 owner 若有重复记录，仅保留最近确认的一条。
    func reconcilePersistedReservations(in ledger: inout NoteImageUploadDailyLedger) {
        ledger.savedCount = max(0, ledger.savedCount)
        var newestByOwner: [NoteImageUploadReservationOwner: NoteImageUploadStoredReservation] = [:]
        for reservation in ledger.reservations.values where reservation.dateBucket == ledger.dateBucket {
            guard reservation.count > 0, reservation.isOwnerConfirmed else { continue }
            if let existing = newestByOwner[reservation.owner],
               existing.updatedAt >= reservation.updatedAt {
                continue
            }
            newestByOwner[reservation.owner] = reservation
        }
        ledger.reservations = Dictionary(
            uniqueKeysWithValues: newestByOwner.values.map { ($0.id, $0) }
        )
    }

    /// 一个草稿 owner 只能由一个持久化 ticket 占额；确认新 ticket 时清理崩溃或覆盖产生的旧票据。
    func removeSiblingReservations(
        of owner: NoteImageUploadReservationOwner,
        keeping reservationID: String,
        from ledger: inout NoteImageUploadDailyLedger
    ) {
        ledger.reservations = ledger.reservations.filter { id, reservation in
            id == reservationID || reservation.owner != owner
        }
    }

    /// 汇总当前日账本的全部活跃票据；切回默认图床时也会计入此前无限制场景建立的草稿票据。
    func totalReservedCount(in ledger: NoteImageUploadDailyLedger) -> Int {
        ledger.reservations.values.reduce(0) { $0 + max(0, $1.count) }
    }

    /// savedCount、reservations 与 committed IDs 编码为同一 Data 后单次写入，避免 ticket→计数转换出现半提交。
    func persistLedger() {
        guard let ledger, let data = try? JSONEncoder().encode(ledger) else { return }
        userDefaults.set(data, forKey: Self.ledgerStorageKey)
    }

    /// 从旧版独立计数 key 迁移当天已保存数量；旧 reservation 没有 owner/确认状态，不能安全继承。
    func legacySavedCount(for bucket: String) -> Int {
        max(0, userDefaults.integer(forKey: "\(Self.legacySavedCountKeyPrefix)\(bucket)"))
    }
}

/// 已解析的当前额度适用条件。
nonisolated private struct NoteImageUploadLimitContext: Sendable {
    let isLimited: Bool
    let dailyLimit: Int
}

private extension NoteImageUploadQuotaState {
    /// 极端编码故障下提供不放宽受限额度的保守快照；正常生产路径始终由已加载 ledger 构建。
    nonisolated static func empty(context: NoteImageUploadLimitContext) -> Self {
        Self(
            isLimited: context.isLimited,
            dailyLimit: context.dailyLimit,
            todaySavedCount: 0,
            currentDraftNewImageCount: 0,
            remainingCount: context.isLimited ? 0 : Int.max
        )
    }
}

/// 单个自然日的完整持久化账本；一次编码同时覆盖已保存计数、活跃票据与幂等提交标记。
nonisolated private struct NoteImageUploadDailyLedger: Codable, Sendable {
    let dateBucket: String
    var savedCount: Int
    var reservations: [String: NoteImageUploadStoredReservation]
    var committedReservationIDs: [String: Date]
}

/// 当天单个编辑草稿持有的持久化预占票据；owner 确认前若进程退出，下一次启动会视为孤儿清理。
nonisolated private struct NoteImageUploadStoredReservation: Codable, Sendable {
    let id: String
    let owner: NoteImageUploadReservationOwner
    let dateBucket: String
    let count: Int
    let updatedAt: Date
    let isOwnerConfirmed: Bool
}
