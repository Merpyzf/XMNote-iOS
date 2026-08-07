/**
 * [INPUT]: 依赖 Foundation 与 BookReadingDetailModels
 * [OUTPUT]: 对外提供 BookReadingDetailRepositoryProtocol，约束单书阅读详情观察、评分/进度/状态写入与偏好持久化
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
    /// 按 Android 状态历史合并规则更新当前阅读状态。
    func updateReadingStatus(bookID: Int64, statusID: Int64, changedAt: Date) async throws
    /// 读取阅读详情页面偏好。
    func fetchSetting() -> BookReadingDetailSetting
    /// 保存阅读详情页面偏好。
    func saveSetting(_ setting: BookReadingDetailSetting)
    /// 读取长图分享开关。
    func fetchShareSetting() -> BookReadingDetailShareSetting
    /// 保存长图分享开关。
    func saveShareSetting(_ setting: BookReadingDetailShareSetting)
}
