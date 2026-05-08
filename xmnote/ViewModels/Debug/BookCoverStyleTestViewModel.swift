#if DEBUG
import Foundation
import SwiftUI

/**
 * [INPUT]: 依赖 XMBookCover 厚度边阈值逻辑，依赖 BookRepositoryProtocol 提供真实封面样例
 * [OUTPUT]: 对外提供 BookCoverStyleTestViewModel（书籍封面样式测试页状态编排）
 * [POS]: Debug 测试状态中枢，集中验证 Apple Books 参考方向的薄厚边样式在尺寸阈值、内容源与业务场景接入下的表现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
final class BookCoverStyleTestViewModel {
    /// DisplayMode 控制实时预览区展示平面封面、Apple Books 参考厚度边或双列对照。
    enum DisplayMode: String, CaseIterable, Identifiable {
        case plain
        case spine
        case sideBySide

        var id: String { rawValue }

        var title: String {
            switch self {
            case .plain:
                return "平面"
            case .spine:
                return "薄厚边"
            case .sideBySide:
                return "对照"
            }
        }
    }

    /// ContentSource 决定测试页展示真实封面、样例封面还是占位封面。
    enum ContentSource: String, CaseIterable, Identifiable {
        case realBooks
        case sampleBooks
        case placeholder

        var id: String { rawValue }

        var title: String {
            switch self {
            case .realBooks:
                return "真实"
            case .sampleBooks:
                return "样例"
            case .placeholder:
                return "占位"
            }
        }
    }

    /// MatrixSize 表示测试页固定验证的四档业务尺寸。
    struct MatrixSize: Identifiable, Hashable {
        let width: CGFloat
        let title: String
        let note: String

        var id: CGFloat { width }
        var height: CGFloat { XMBookCover.height(forWidth: width) }
    }

    var displayMode: DisplayMode = .sideBySide
    var contentSource: ContentSource = .sampleBooks
    var livePreviewWidth: CGFloat = 80
    var isLoadingRealBookCovers = false
    var realBookCoverStatusMessage: String?
    var bookSourceTotalCount: Int = 0
    var validBookCoverCount: Int = 0

    private let fallbackCoverURLs: [String] = [
        "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Example.jpg/320px-Example.jpg",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/8/84/Example.svg/320px-Example.svg.png",
        "https://www.gstatic.com/webp/gallery/1.sm.webp",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/f/fa/Apple_logo_black.svg/320px-Apple_logo_black.svg.png"
    ]
    private var realBookCoverURLs: [String] = []
    private var hasLoadedRealBookCovers = false

    let matrixSizes: [MatrixSize] = [
        MatrixSize(width: 54, title: "54pt", note: "时间线级小封面"),
        MatrixSize(width: 70, title: "70pt", note: "在读首页封面"),
        MatrixSize(width: 80, title: "80pt", note: "详情头部封面"),
        MatrixSize(width: 110, title: "110pt", note: "书库网格封面")
    ]

    var livePreviewHeight: CGFloat {
        XMBookCover.height(forWidth: livePreviewWidth)
    }

    var livePreviewTier: XMBookCover.SurfaceTier {
        XMBookCover.resolvedSurfaceTier(
            for: CGSize(width: livePreviewWidth, height: livePreviewHeight),
            requestedStyle: .spine
        )
    }

    var livePreviewTierDescription: String {
        switch livePreviewTier {
        case .plain:
            return "当前尺寸低于厚度边阈值，将自动回退为平面封面。"
        case .thinEdge:
            return "当前尺寸命中 Thin Edge，只保留极薄左侧厚度边与短阴影过渡。"
        case .depthEdge:
            return "当前尺寸命中 Depth Edge，会增加一点厚度和外部悬浮感，但仍以封面正面为主。"
        }
    }

    var activeSourceTitle: String {
        switch contentSource {
        case .realBooks:
            if realBookCoverURLs.isEmpty {
                return "真实封面为空，已回退样例封面"
            }
            return "真实封面（\(validBookCoverCount)/\(bookSourceTotalCount)）"
        case .sampleBooks:
            return "样例封面"
        case .placeholder:
            return "占位封面"
        }
    }

    var sourceStatusMessage: String? {
        switch contentSource {
        case .realBooks:
            return realBookCoverStatusMessage
        case .sampleBooks, .placeholder:
            return nil
        }
    }

    var livePreviewURL: String {
        coverURL(at: 0)
    }

    /// 首次按需加载真实封面样例，避免重复触发仓储观察流。
    func loadBookCoversIfNeeded(using repository: any BookRepositoryProtocol) async {
        guard !hasLoadedRealBookCovers else { return }
        await loadBookCovers(using: repository)
    }

    /// 返回指定索引的封面 URL；占位模式固定返回空串触发 placeholder。
    func coverURL(at index: Int) -> String {
        guard contentSource != .placeholder else { return "" }

        let urls: [String]
        switch contentSource {
        case .realBooks:
            urls = realBookCoverURLs.isEmpty ? fallbackCoverURLs : realBookCoverURLs
        case .sampleBooks:
            urls = fallbackCoverURLs
        case .placeholder:
            urls = []
        }

        guard !urls.isEmpty else { return "" }
        return urls[index % urls.count]
    }
}

private extension BookCoverStyleTestViewModel {
    func loadBookCovers(using repository: any BookRepositoryProtocol) async {
        isLoadingRealBookCovers = true
        realBookCoverStatusMessage = nil
        defer {
            isLoadingRealBookCovers = false
            hasLoadedRealBookCovers = true
        }

        do {
            var books: [BookItem] = []
            for try await observed in repository.observeBooks() {
                books = observed
                break
            }

            let normalized = books.compactMap { normalizeCoverURL($0.cover) }
            let deduplicated = deduplicatedPreservingOrder(normalized)

            bookSourceTotalCount = books.count
            validBookCoverCount = deduplicated.count
            realBookCoverURLs = deduplicated

            if deduplicated.isEmpty {
                realBookCoverStatusMessage = "本地 Book 表暂无有效封面，已回退到样例封面。"
            }
        } catch {
            realBookCoverStatusMessage = "真实封面加载失败：\(error.localizedDescription)"
        }
    }

    func normalizeCoverURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func deduplicatedPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
#endif
