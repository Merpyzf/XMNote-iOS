import Foundation
import UIKit

/**
 * [INPUT]: 依赖 App Group 共享容器、XMCoverImageLoading 与阅读计时书籍封面 URL
 * [OUTPUT]: 对外提供 ReadingTimerLiveActivityCoverSnapshotStore，把当前计时书籍封面写成 Widget 可读取的小图快照
 * [POS]: Infra/LiveActivity 封面桥接层，保证阅读计时 Live Activity 在灵动岛中稳定显示真实书籍封面
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
/// 阅读计时 Live Activity 封面快照仓库，负责把 App 内封面缓存到 App Group 供 Widget 同步读取。
final class ReadingTimerLiveActivityCoverSnapshotStore {
    static let shared = ReadingTimerLiveActivityCoverSnapshotStore()

    private static let appGroupIdentifier = "group.com.merpyzf.xmnote"
    private static let coverDirectoryName = "ReadingTimerCovers"
    private static let snapshotSize = CGSize(width: 144, height: 212)
    private static let retryInterval: TimeInterval = 300

    private let imageLoader: any XMCoverImageLoading
    private let fileManager: FileManager
    private var failedSnapshotDates: [String: Date] = [:]

    /// 注入封面加载器与文件系统，便于复用现有图片请求头、缓存策略与后续测试替换。
    init(
        imageLoader: (any XMCoverImageLoading)? = nil,
        fileManager: FileManager = .default
    ) {
        self.imageLoader = imageLoader ?? NukeCoverImageLoader()
        self.fileManager = fileManager
    }

    /// 为当前书籍生成或复用封面快照文件名；失败时返回 nil，让 Widget 走远程 URL 或中性封面兜底。
    /// 并发语义：方法运行在 MainActor；图片下载通过 Nuke 异步执行，写入失败不会影响计时状态同步。
    func prepareSnapshotName(bookId: Int64, coverURLString: String?) async -> String? {
        guard let coverURLString,
              let coverURL = XMImageRequestBuilder.normalizedURL(from: coverURLString),
              let directoryURL = makeCoverDirectoryIfNeeded() else {
            return nil
        }

        let snapshotKey = Self.snapshotKey(bookId: bookId, coverURLString: coverURL.absoluteString)
        if let failedAt = failedSnapshotDates[snapshotKey],
           Date().timeIntervalSince(failedAt) < Self.retryInterval {
            return nil
        }

        let snapshotName = Self.snapshotName(snapshotKey: snapshotKey)
        let snapshotURL = directoryURL.appendingPathComponent(snapshotName, isDirectory: false)
        if fileManager.fileExists(atPath: snapshotURL.path) {
            failedSnapshotDates.removeValue(forKey: snapshotKey)
            return snapshotName
        }

        do {
            let request = XMImageLoadRequest(
                url: coverURL,
                priority: .high,
                timeout: 8,
                cachePolicy: .returnCacheDataElseLoad
            )
            let image = try await imageLoader.loadImage(for: request)
            guard let data = Self.snapshotJPEGData(from: image) else {
                failedSnapshotDates[snapshotKey] = Date()
                return nil
            }
            try data.write(to: snapshotURL, options: .atomic)
            failedSnapshotDates.removeValue(forKey: snapshotKey)
            return snapshotName
        } catch {
            failedSnapshotDates[snapshotKey] = Date()
            return nil
        }
    }

    private func makeCoverDirectoryIfNeeded() -> URL? {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            return nil
        }
        let directoryURL = containerURL.appendingPathComponent(Self.coverDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            return directoryURL
        } catch {
            return nil
        }
    }

    private static func snapshotKey(bookId: Int64, coverURLString: String) -> String {
        "\(bookId)|\(coverURLString)"
    }

    private static func snapshotName(snapshotKey: String) -> String {
        "reading_timer_\(stableHash(for: snapshotKey)).jpg"
    }

    private static func stableHash(for text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func snapshotJPEGData(from image: UIImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true

        let renderer = UIGraphicsImageRenderer(size: snapshotSize, format: rendererFormat)
        return renderer.jpegData(withCompressionQuality: 0.82) { context in
            UIColor.secondarySystemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: snapshotSize))

            let scale = max(snapshotSize.width / image.size.width, snapshotSize.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let drawOrigin = CGPoint(
                x: (snapshotSize.width - drawSize.width) / 2,
                y: (snapshotSize.height - drawSize.height) / 2
            )
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }
}
