/**
 * [INPUT]: 依赖 DesktopWebReviewRepository 的数据库、草稿无关 DTO、富文本规范化器、毫秒时钟与上传票据提交闭包
 * [OUTPUT]: 对外提供 Android ReviewService 的创建、局部更新和软删除图谱语义
 * [POS]: Data 层网页书评写入扩展；事务边界按 Android 当前 Web 实现逐项复刻
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated extension DesktopWebReviewRepository {
    /// 创建书评并在单一数据库事务中写入图片和提交上传票据。
    func createReview(_ input: DesktopWebReviewCreateInput) async throws -> DesktopWebBookReviewSnapshot {
        try await requireActiveBook(
            input.bookID,
            error: .invalidArgument("书籍不存在: \(input.bookID)")
        )
        let title = Self.kotlinTrimmed(input.title ?? "")
        let content = input.content.map(DesktopWebRichHTMLCanonicalizer.canonicalize) ?? ""
        guard !Self.isKotlinBlank(title) || !Self.isKotlinBlank(content) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("请至少填写一项内容（标题、书评内容）")
        }
        let imageURLs = Self.normalizedImageURLs(input.imageURLs) ?? []
        let now = currentTimeMillis()
        let createdTime = input.createdTime.flatMap { $0 > 0 ? $0 : nil } ?? now
        let reviewID = try await database.dbPool.write { db -> Int64 in
            var review = ReviewRecord()
            review.bookId = input.bookID
            review.title = title
            review.content = content
            review.createdDate = createdTime
            review.updatedDate = now
            try review.insert(db)
            guard let reviewID = review.id else {
                throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("创建书评失败")
            }
            try Self.replaceReviewImages(
                db: db,
                reviewID: reviewID,
                imageURLs: imageURLs,
                now: now
            )
            try commitUploadedTickets(input.uploadedTicketIDs, imageURLs)
            return reviewID
        }
        return try await review(id: reviewID)
    }

    /// 局部更新书评；nil 图片保留原图，显式空数组软删除全部旧图。
    func updateReview(
        id: Int64,
        input: DesktopWebReviewUpdateInput
    ) async throws -> DesktopWebBookReviewSnapshot {
        var review = try await requireReviewFromActiveBook(id: id)
        let targetTitle = input.title.map(Self.kotlinTrimmed) ?? (review.title ?? "")
        let normalizedContent = input.content.map(DesktopWebRichHTMLCanonicalizer.canonicalize)
        let targetContent = normalizedContent ?? (review.content ?? "")
        guard !Self.isKotlinBlank(targetTitle) || !Self.isKotlinBlank(targetContent) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("请至少填写一项内容（标题、书评内容）")
        }
        let imageURLs: [String]
        if let requestedImageURLs = input.imageURLs {
            imageURLs = Self.normalizedImageURLs(requestedImageURLs) ?? []
        } else {
            imageURLs = try await activeReviewImageURLs(reviewID: id)
        }
        let now = currentTimeMillis()
        if input.title != nil { review.title = targetTitle }
        if normalizedContent != nil { review.content = targetContent }
        if let createdTime = input.createdTime, createdTime > 0 { review.createdDate = createdTime }
        review.updatedDate = now

        let updatedReview = review
        try await database.dbPool.write { db in
            try updatedReview.update(db)
            if input.imageURLs != nil {
                try Self.replaceReviewImages(
                    db: db,
                    reviewID: id,
                    imageURLs: imageURLs,
                    now: now
                )
                try commitUploadedTickets(input.uploadedTicketIDs, imageURLs)
            }
        }
        return try await self.review(id: id)
    }

    /// 在单一事务内软删除有效书籍下的书评及其图片。
    func deleteReview(id: Int64) async throws {
        _ = try await requireReviewFromActiveBook(id: id)
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            try db.execute(
                // SQL 目的：先软删除目标书评的全部有效图片。
                // 涉及表：review_image。
                // 关键过滤：review_id 精确匹配且 is_deleted=0。
                // 时间字段：updated_date 使用与主记录删除相同的服务层毫秒值。
                // 副作用用途：DELETE /reviews/{id} 的同事务图片清理。
                sql: "UPDATE review_image SET is_deleted = 1, updated_date = ? WHERE review_id = ? AND is_deleted = 0",
                arguments: [now, id]
            )
            try db.execute(
                // SQL 目的：软删除目标有效书评主记录。
                // 涉及表：review。
                // 关键过滤：id 精确匹配且 is_deleted=0。
                // 时间字段：updated_date 使用服务层同一毫秒值。
                // 副作用用途：DELETE /reviews/{id} 的同事务主记录删除。
                sql: "UPDATE review SET is_deleted = 1, updated_date = ? WHERE id = ? AND is_deleted = 0",
                arguments: [now, id]
            )
            guard db.changesCount > 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("书评不存在: \(id)")
            }
        }
    }
}

private nonisolated extension DesktopWebReviewRepository {
    func activeReviewImageURLs(reviewID: Int64) async throws -> [String] {
        try await database.dbPool.read { db in
            try ReviewImageRecord
                .filter(Column("review_id") == reviewID && Column("is_deleted") == 0)
                .order(Column("order").asc)
                .fetchAll(db)
                .map(\.image)
        }
    }

    static func replaceReviewImages(
        db: Database,
        reviewID: Int64,
        imageURLs: [String],
        now: Int64
    ) throws {
        try db.execute(
            // SQL 目的：软删除书评已有的全部有效图片后重建请求顺序。
            // 涉及表：review_image。
            // 关键过滤：review_id 精确匹配且 is_deleted=0。
            // 时间字段：旧行 updated_date 使用本次书评写入毫秒值。
            // 副作用用途：创建/更新书评图片替换事务。
            sql: "UPDATE review_image SET is_deleted = 1, updated_date = ? WHERE review_id = ? AND is_deleted = 0",
            arguments: [now, reviewID]
        )
        for (index, url) in imageURLs.enumerated() {
            var image = ReviewImageRecord()
            image.reviewId = reviewID
            image.image = url
            image.order = Int64(index)
            image.createdDate = now
            try image.insert(db)
        }
    }

    static func normalizedImageURLs(_ values: [String]?) -> [String]? {
        values?.map(kotlinTrimmed).filter { !$0.isEmpty }
    }
}
