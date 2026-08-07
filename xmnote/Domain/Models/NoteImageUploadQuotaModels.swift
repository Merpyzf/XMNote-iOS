/**
 * [INPUT]: 依赖 Foundation 提供跨层值类型语义
 * [OUTPUT]: 对外提供 NoteImageUploadReservationOwner、NoteImageUploadQuotaState 与 NoteImageUploadReservationResult，描述草稿/合并会话归属、每日额度和原子申请结果
 * [POS]: Domain/Models 的图片上传额度模型，被仓储、三类内容编辑器与书摘合并页共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 图片额度票据的稳定草稿归属，用于跨启动清理同一自动草稿遗留的旧 reservation。
nonisolated struct NoteImageUploadReservationOwner: Hashable, Codable, Sendable {
    let rawValue: String

    /// 书摘草稿沿用 UserDefaults 的 `(book_id, note_id)` 身份；同一身份只应保留一个有效额度票据。
    static func note(bookID: Int64, noteID: Int64) -> Self {
        Self(rawValue: "note:\(bookID):\(noteID)")
    }

    /// 书评草稿沿用 `(book_id, review_id)` 身份，新建书评以 reviewID=0 表示。
    static func review(bookID: Int64, reviewID: Int64) -> Self {
        Self(rawValue: "review:\(bookID):\(reviewID)")
    }

    /// 相关内容草稿沿用 `(book_id, category_id, content_id)` 身份，新建内容以 contentID=0 表示。
    static func relevant(bookID: Int64, categoryID: Int64, contentID: Int64) -> Self {
        Self(rawValue: "relevant:\(bookID):\(categoryID):\(contentID)")
    }

    /// 合并会话以目标书和有序来源书摘为稳定身份；未持久化页面退出后不会跨启动保留票据。
    static func merge(bookID: Int64, noteIDs: [Int64]) -> Self {
        let sourceIdentity = noteIDs.sorted().map(String.init).joined(separator: ",")
        return Self(rawValue: "merge:\(bookID):\(sourceIdentity)")
    }
}

/// 图片上传额度快照，对齐 Android 当前日桶、已保存数量和当前草稿新图预占算法。
nonisolated struct NoteImageUploadQuotaState: Equatable, Sendable {
    let isLimited: Bool
    let dailyLimit: Int
    let todaySavedCount: Int
    let currentDraftNewImageCount: Int
    let remainingCount: Int

    var isBlocked: Bool {
        isLimited && remainingCount <= 0
    }

    /// 达到上限时使用的业务说明，由现有 XMSystemAlert 统一展示。
    var blockedMessage: String {
        let displayedUsedCount = max(
            todaySavedCount + currentDraftNewImageCount,
            dailyLimit
        )
        return "今日图片已达上限（\(displayedUsedCount)/\(dailyLimit)）。\n开通高级版或使用自定义图床后可继续上传。"
    }

    /// 计算本次选择可接纳数量；无限制场景直接保留全部。
    func acceptedCount(for requestedCount: Int) -> Int {
        guard requestedCount > 0 else { return 0 }
        guard isLimited else { return requestedCount }
        return min(requestedCount, max(0, remainingCount))
    }
}

/// 一次原子图片预占的结果，acceptedCount 是调用方本次可以真正进入草稿的数量。
nonisolated struct NoteImageUploadReservationResult: Equatable, Sendable {
    let acceptedCount: Int
    let state: NoteImageUploadQuotaState
}
