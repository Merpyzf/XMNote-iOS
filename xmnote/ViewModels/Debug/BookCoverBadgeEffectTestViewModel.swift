#if DEBUG
import Foundation
import UIKit

/**
 * [INPUT]: 依赖 BookRepositoryProtocol 读取真实书籍封面样例，依赖 UIKit 提供系统毛玻璃样式枚举
 * [OUTPUT]: 对外提供 BookCoverBadgeEffectTestViewModel（书封角标效果测试页状态编排）
 * [POS]: Debug 测试状态中枢，集中管理书封角标毛玻璃参数、样例封面与参数摘要
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
final class BookCoverBadgeEffectTestViewModel {
    /// PreviewMode 控制下方对照区域展示实时、Blur Style、封面矩阵或主题/分组验证。
    enum PreviewMode: String, CaseIterable, Identifiable, Hashable {
        case live
        case blurStyles
        case matrix
        case themeAndGroup

        var id: String { rawValue }

        var title: String {
            switch self {
            case .live:
                return "实时"
            case .blurStyles:
                return "Blur 对比"
            case .matrix:
                return "封面矩阵"
            case .themeAndGroup:
                return "主题/分组"
            }
        }
    }

    /// ParameterGroup 表示可折叠参数分组，默认只展开玻璃层。
    enum ParameterGroup: String, CaseIterable, Identifiable, Hashable {
        case glass
        case text
        case size
        case status
        case experiment

        var id: String { rawValue }

        var title: String {
            switch self {
            case .glass:
                return "玻璃层"
            case .text:
                return "文字层"
            case .size:
                return "尺寸层"
            case .status:
                return "阅读状态"
            case .experiment:
                return "实验开关"
            }
        }
    }

    /// BlurStyleOption 将系统 UIBlurEffect.Style 收敛为测试页可比较的四个候选。
    enum BlurStyleOption: String, CaseIterable, Identifiable, Hashable {
        case ultraThin
        case thin
        case ultraThinDark
        case thinDark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ultraThin:
                return "Ultra Thin"
            case .thin:
                return "Thin"
            case .ultraThinDark:
                return "Ultra Thin Dark"
            case .thinDark:
                return "Thin Dark"
            }
        }

        var uiBlurStyle: UIBlurEffect.Style {
            switch self {
            case .ultraThin:
                return .systemUltraThinMaterial
            case .thin:
                return .systemThinMaterial
            case .ultraThinDark:
                return .systemUltraThinMaterialDark
            case .thinDark:
                return .systemThinMaterialDark
            }
        }
    }

    /// BadgeEffectParameters 承载测试页所有可调角标视觉参数。
    struct BadgeEffectParameters: Equatable {
        var blurStyle: BlurStyleOption = .ultraThin
        var darkOverlayOpacity = 0.22
        var washOpacity = 0.02
        var strokeOpacity = 0.08
        var contentShadowOpacity = 0.26
        var contentShadowRadius = 0.6
        var contentShadowYOffset = 0.4
        var horizontalPadding = 6.0
        var verticalPadding = 3.0
        var pinSize = 22.0
        var innerCornerRadius = 6.0
        var statusOpacity = 0.92
        var usesVibrancyText = false
    }

    /// CoverSample 表示调参页展示的一张封面样例。
    struct CoverSample: Identifiable, Hashable {
        enum Kind: Hashable {
            case real
            case fixed
            case placeholder
        }

        let id: String
        let title: String
        let note: String
        let urlString: String
        let kind: Kind
    }

    var parameters = BadgeEffectParameters()
    var previewMode: PreviewMode = .live
    var expandedParameterGroups: Set<ParameterGroup> = [.glass]
    var selectedSampleID: String?
    var isLoadingRealBookCovers = false
    var realBookCoverStatusMessage: String?
    var bookSourceTotalCount = 0
    var validBookCoverCount = 0

    private var realSamples: [CoverSample] = []
    private var hasLoadedRealBookCovers = false

    var allSamples: [CoverSample] {
        let real = realSamples.prefix(6)
        return Array(real) + Self.fixedSamples
    }

    var matrixSamples: [CoverSample] {
        let real = realSamples.prefix(3)
        return Array(real) + Self.fixedSamples
    }

    var selectedSample: CoverSample {
        if let selectedSampleID,
           let sample = allSamples.first(where: { $0.id == selectedSampleID }) {
            return sample
        }
        return allSamples.first ?? Self.placeholderSample
    }

    var sourceStatusText: String {
        if isLoadingRealBookCovers {
            return "正在读取本地真实封面样例..."
        }
        if let realBookCoverStatusMessage {
            return realBookCoverStatusMessage
        }
        if realSamples.isEmpty {
            return "暂无真实封面，当前使用固定样例。"
        }
        return "真实封面 \(validBookCoverCount)/\(bookSourceTotalCount)，并补充固定极端样例。"
    }

    var parameterSummary: String {
        """
        blurStyle: \(parameters.blurStyle.title)
        darkOverlayOpacity: \(format(parameters.darkOverlayOpacity))
        washOpacity: \(format(parameters.washOpacity))
        strokeOpacity: \(format(parameters.strokeOpacity))
        contentShadowOpacity: \(format(parameters.contentShadowOpacity))
        contentShadowRadius: \(format(parameters.contentShadowRadius))
        contentShadowYOffset: \(format(parameters.contentShadowYOffset))
        horizontalPadding: \(format(parameters.horizontalPadding))
        verticalPadding: \(format(parameters.verticalPadding))
        pinSize: \(format(parameters.pinSize))
        innerCornerRadius: \(format(parameters.innerCornerRadius))
        statusOpacity: \(format(parameters.statusOpacity))
        usesVibrancyText: \(parameters.usesVibrancyText)
        """
    }

    /// 首次按需加载本地真实封面，避免测试页重复订阅书籍观察流。
    func loadBookCoversIfNeeded(using repository: any BookRepositoryProtocol) async {
        guard !hasLoadedRealBookCovers else { return }
        await loadBookCovers(using: repository)
    }

    /// 将所有参数恢复到推荐初始值，便于对比实验后快速回到基线。
    func resetParameters() {
        parameters = BadgeEffectParameters()
    }

    /// 切换指定参数分组的展开状态，使用 Set 保持状态简单可追踪。
    func toggleParameterGroup(_ group: ParameterGroup) {
        if expandedParameterGroups.contains(group) {
            expandedParameterGroups.remove(group)
        } else {
            expandedParameterGroups.insert(group)
        }
    }

    /// 判断参数分组是否已展开，供测试页折叠控件读取。
    func isParameterGroupExpanded(_ group: ParameterGroup) -> Bool {
        expandedParameterGroups.contains(group)
    }

    /// 返回指定 blur style 覆盖后的参数副本，用于横向对比矩阵。
    func parameters(overriding blurStyle: BlurStyleOption) -> BadgeEffectParameters {
        var copy = parameters
        copy.blurStyle = blurStyle
        return copy
    }
}

private extension BookCoverBadgeEffectTestViewModel {
    static let placeholderSample = CoverSample(
        id: "placeholder",
        title: "占位",
        note: "无封面回退",
        urlString: "",
        kind: .placeholder
    )

    static let fixedSamples: [CoverSample] = [
        CoverSample(
            id: "fixed-light",
            title: "浅色",
            note: "浅底低对比",
            urlString: "https://dummyimage.com/400x600/f7f3df/667243.png&text=LIGHT",
            kind: .fixed
        ),
        CoverSample(
            id: "fixed-yellow",
            title: "黄色",
            note: "高饱和暖色",
            urlString: "https://dummyimage.com/400x600/f6d21b/111111.png&text=YELLOW",
            kind: .fixed
        ),
        CoverSample(
            id: "fixed-dark",
            title: "黑色",
            note: "深色封面",
            urlString: "https://dummyimage.com/400x600/101820/8fd7ff.png&text=DARK",
            kind: .fixed
        ),
        CoverSample(
            id: "fixed-white",
            title: "白底",
            note: "白底黑字",
            urlString: "https://dummyimage.com/400x600/ffffff/111111.png&text=WHITE",
            kind: .fixed
        ),
        CoverSample(
            id: "fixed-colorful",
            title: "复杂",
            note: "复杂彩色背景",
            urlString: "https://picsum.photos/seed/xmnote-badge-effect/400/600",
            kind: .fixed
        ),
        placeholderSample
    ]

    func loadBookCovers(using repository: any BookRepositoryProtocol) async {
        isLoadingRealBookCovers = true
        realBookCoverStatusMessage = nil
        defer {
            isLoadingRealBookCovers = false
            hasLoadedRealBookCovers = true
            if selectedSampleID == nil {
                selectedSampleID = allSamples.first?.id
            }
        }

        do {
            var books: [BookItem] = []
            for try await observed in repository.observeBooks() {
                books = observed
                break
            }

            let urls = deduplicatedPreservingOrder(books.compactMap { normalizeCoverURL($0.cover) })
            bookSourceTotalCount = books.count
            validBookCoverCount = urls.count
            realSamples = urls.prefix(6).enumerated().map { index, url in
                CoverSample(
                    id: "real-\(index)-\(url.hashValue)",
                    title: "真实 \(index + 1)",
                    note: "本地书库封面",
                    urlString: url,
                    kind: .real
                )
            }

            if urls.isEmpty {
                realBookCoverStatusMessage = "本地 Book 表暂无有效封面，已回退固定样例。"
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

    func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
#endif
