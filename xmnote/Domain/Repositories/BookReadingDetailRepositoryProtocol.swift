/**
 * [INPUT]: 依赖 Foundation 与 BookReadingDetailModels
 * [OUTPUT]: 对外提供 BookReadingDetailRepositoryProtocol，约束单书阅读详情观察、评分/进度/状态 CRUD、庆祝追踪与偏好持久化
 * [POS]: Domain/Repositories 层窄职责契约，被阅读详情 ViewModel 依赖
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 单书阅读详情仓储契约；所有数据库与偏好读写均在实现层完成。
protocol BookReadingDetailRepositoryProtocol {
    /// 观察书籍、内容活动、有效计时、打卡及阅读状态变化，并返回 Android 口径的完整页面快照。
    func observeSnapshot(bookID: Int64) -> AsyncThrowingStream<BookReadingDetailSnapshot?, Error>
    /// 更新 0...50 的业务评分。
    func updateRating(bookID: Int64, score: Int64) async throws
    /// 按书籍既有进度单位更新当前值及可选总值。
    func updateProgress(bookID: Int64, input: BookReadingProgressInput) async throws
    /// 追加一条新阅读状态；同状态也保留为独立历史，并执行时间单调性校验。
    func addReadingStatus(bookID: Int64, statusID: Int64, changedAt: Date) async throws
    /// 精确更新一条现有阅读状态，并按 created_date 最新记录重算书籍当前状态。
    func updateReadingStatus(bookID: Int64, recordID: Int64, statusID: Int64, changedAt: Date) async throws
    /// 软删除一条现有阅读状态；仅剩一条有效历史时拒绝删除。
    func deleteReadingStatus(bookID: Int64, recordID: Int64) async throws
    /// 查询累计读完书数、本年读完书数和本年目标；目标缺失时按 Android 默认值 12 落库。
    func fetchCompletionTracker() async throws -> BookReadingCompletionTracker
    /// 读取阅读详情页面偏好。
    func fetchSetting() -> BookReadingDetailSetting
    /// 保存阅读详情页面偏好。
    func saveSetting(_ setting: BookReadingDetailSetting)
    /// 读取长图分享开关。
    func fetchShareSetting() -> BookReadingDetailShareSetting
    /// 保存长图分享开关。
    func saveShareSetting(_ setting: BookReadingDetailShareSetting)
}
