/**
 * [INPUT]: 依赖 Foundation 基础类型，承接 Android 书摘回顾设置与卡片数据语义
 * [OUTPUT]: 对外提供 NoteReviewSettings、NoteReviewCardItem、NoteReviewTagOption 与标签编辑快照等跨层模型
 * [POS]: Domain/Models 的书摘回顾领域模型，供 Repository、ViewModel 与回顾页面共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书摘回顾的数据排序规则，对齐 Android 的随机与顺序两种模式。
nonisolated enum NoteReviewSortRule: String, CaseIterable, Codable, Hashable, Sendable {
    case random
    case ordered

    var title: String {
        switch self {
        case .random:
            return "随机回顾"
        case .ordered:
            return "按书籍顺序"
        }
    }

    var systemImage: String {
        switch self {
        case .random:
            return "shuffle"
        case .ordered:
            return "text.line.first.and.arrowtriangle.forward"
        }
    }
}

/// 标签筛选匹配规则，承接 Android “任一标签/全部标签”语义。
nonisolated enum NoteReviewTagMatchRule: String, CaseIterable, Codable, Hashable, Sendable {
    case any
    case all

    var title: String {
        switch self {
        case .any:
            return "任一标签"
        case .all:
            return "全部标签"
        }
    }
}

/// 回顾卡片色彩集合，以亮暗模式的纯色背景与文本色描述可渲染的配色语义。
nonisolated struct NoteReviewCardColorSet: Hashable, Sendable {
    let lightSurfaceHex: UInt32
    let darkSurfaceHex: UInt32
    let lightTextHex: UInt32
    let darkTextHex: UInt32

    /// 按显式亮暗外观返回卡片表面色，供 SwiftUI 与 UIKit 从同一领域数据解析。
    func surfaceHex(isDarkAppearance: Bool) -> UInt32 {
        isDarkAppearance ? darkSurfaceHex : lightSurfaceHex
    }

    /// 按显式亮暗外观返回卡片 on-surface 文字色，避免渲染路径依赖环境 trait。
    func textHex(isDarkAppearance: Bool) -> UInt32 {
        isDarkAppearance ? darkTextHex : lightTextHex
    }
}

/// 回顾卡片配色预设；保留历史 raw value，并向 UI 层提供规范化的颜色语义。
nonisolated enum NoteReviewPalette: String, CaseIterable, Codable, Hashable, Sendable {
    case paper
    case dark
    case lightGray
    case mistBlue
    case sageGreen
    case warmSand
    case skyBlue
    case rose

    /// 供用户选择的五种标准配色，不包含仅用于解码兼容的历史值。
    static let selectablePalettes: [NoteReviewPalette] = [
        .paper,
        .dark,
        .sageGreen,
        .mistBlue,
        .rose
    ]

    /// 仅枚举当前可选的规范化配色，避免历史持久化值回流到选择界面。
    static let allCases: [NoteReviewPalette] = selectablePalettes

    /// 将历史持久化值映射为当前标准配色，避免其继续扩散到新的设置数据中。
    var canonicalPalette: NoteReviewPalette {
        switch self {
        case .lightGray:
            return .paper
        case .warmSand:
            return .rose
        case .skyBlue:
            return .mistBlue
        case .paper, .dark, .sageGreen, .mistBlue, .rose:
            return self
        }
    }

    /// 返回规范化配色的用户可见名称，确保历史值也展示当前标准名称。
    var title: String {
        switch canonicalPalette {
        case .paper:
            return "雾白"
        case .dark:
            return "石墨"
        case .mistBlue:
            return "潮雾"
        case .sageGreen:
            return "苔岩"
        case .rose:
            return "陶土"
        case .lightGray, .warmSand, .skyBlue:
            preconditionFailure("历史配色必须先归一化")
        }
    }

    /// 返回规范化配色在亮暗模式下使用的纯色背景与文本色，作为卡片色彩的唯一真相源。
    var cardColorSet: NoteReviewCardColorSet {
        switch canonicalPalette {
        case .paper:
            return NoteReviewCardColorSet(
                lightSurfaceHex: 0xF7F9F7,
                darkSurfaceHex: 0x202723,
                lightTextHex: 0x29332D,
                darkTextHex: 0xE6ECE7
            )
        case .dark:
            return NoteReviewCardColorSet(
                lightSurfaceHex: 0x2C3430,
                darkSurfaceHex: 0x1D2420,
                lightTextHex: 0xF3F6F3,
                darkTextHex: 0xEAF0EB
            )
        case .sageGreen:
            return NoteReviewCardColorSet(
                lightSurfaceHex: 0xE2EAE1,
                darkSurfaceHex: 0x29342D,
                lightTextHex: 0x304137,
                darkTextHex: 0xE1E9E1
            )
        case .mistBlue:
            return NoteReviewCardColorSet(
                lightSurfaceHex: 0xE5ECEE,
                darkSurfaceHex: 0x273136,
                lightTextHex: 0x334149,
                darkTextHex: 0xE1E9EC
            )
        case .rose:
            return NoteReviewCardColorSet(
                lightSurfaceHex: 0xF0E6DF,
                darkSurfaceHex: 0x392B26,
                lightTextHex: 0x4A3931,
                darkTextHex: 0xF1E6DE
            )
        case .lightGray, .warmSand, .skyBlue:
            preconditionFailure("历史配色必须先归一化")
        }
    }

    /// 兼容既有调用，返回规范化配色的浅色纯色背景起点。
    var defaultBackgroundStartHex: UInt32 {
        cardColorSet.lightSurfaceHex
    }

    /// 兼容既有调用，返回规范化配色的浅色纯色背景终点。
    var defaultBackgroundEndHex: UInt32 {
        cardColorSet.lightSurfaceHex
    }

    /// 兼容既有调用，返回规范化配色的浅色文本颜色。
    var defaultTextColorHex: UInt32 {
        cardColorSet.lightTextHex
    }
}

/// 回顾卡片背景来源，保留 Android 的纯色/图片两种配置能力。
nonisolated enum NoteReviewBackgroundMode: String, CaseIterable, Codable, Hashable, Sendable {
    case color
    case image

    var title: String {
        switch self {
        case .color: "颜色"
        case .image: "图片"
        }
    }
}

/// 回顾卡片字体来源，支持系统字体、内置衬线字体和导入的本地字体。
nonisolated enum NoteReviewFontSelection: Hashable, Sendable, Codable {
    case system
    case sourceHanSerif
    case local(fileName: String, displayName: String)

    private enum CodingKeys: String, CodingKey {
        case kind, fileName, displayName
    }

    private enum Kind: String, Codable {
        case system
        case sourceHanSerif
        case local
    }

    var title: String {
        switch self {
        case .system:
            return "系统默认"
        case .sourceHanSerif:
            return "衬线字体"
        case .local(_, let displayName):
            return displayName
        }
    }

    var localFileName: String? {
        guard case .local(let fileName, _) = self else { return nil }
        return fileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .system:
            self = .system
        case .sourceHanSerif:
            self = .sourceHanSerif
        case .local:
            self = .local(
                fileName: try container.decode(String.self, forKey: .fileName),
                displayName: try container.decode(String.self, forKey: .displayName)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system:
            try container.encode(Kind.system, forKey: .kind)
        case .sourceHanSerif:
            try container.encode(Kind.sourceHanSerif, forKey: .kind)
        case .local(let fileName, let displayName):
            try container.encode(Kind.local, forKey: .kind)
            try container.encode(fileName, forKey: .fileName)
            try container.encode(displayName, forKey: .displayName)
        }
    }
}

/// 回顾卡片文本对齐方式，保留 Android 的三种阅读布局能力。
nonisolated enum NoteReviewTextAlignment: String, CaseIterable, Codable, Hashable, Sendable {
    case leading
    case center
    case trailing

    var title: String {
        switch self {
        case .leading:
            return "靠左"
        case .center:
            return "居中"
        case .trailing:
            return "靠右"
        }
    }
}

/// 书摘回顾设置快照，集中描述会影响数据读取和外观渲染的全部用户偏好。
nonisolated struct NoteReviewSettings: Codable, Hashable, Sendable {
    var selectedBookIDs: [Int64]
    var selectedTagIDs: [Int64]
    var tagMatchRule: NoteReviewTagMatchRule
    var sortRule: NoteReviewSortRule
    var palette: NoteReviewPalette
    var textAlignment: NoteReviewTextAlignment
    var backgroundMode: NoteReviewBackgroundMode
    var backgroundImageURL: String?
    var customBackgroundStartHex: UInt32?
    var customBackgroundEndHex: UInt32?
    var customTextColorHex: UInt32?
    var fontSelection: NoteReviewFontSelection

    private enum CodingKeys: String, CodingKey {
        case selectedBookIDs, selectedTagIDs, tagMatchRule, sortRule, palette, textAlignment
        case backgroundMode, backgroundImageURL
        case customBackgroundStartHex, customBackgroundEndHex, customTextColorHex
        case fontSelection
    }

    static let defaultValue = NoteReviewSettings(
        selectedBookIDs: [],
        selectedTagIDs: [],
        tagMatchRule: .any,
        sortRule: .random,
        palette: .paper,
        textAlignment: .leading,
        backgroundMode: .color,
        backgroundImageURL: nil,
        customBackgroundStartHex: nil,
        customBackgroundEndHex: nil,
        customTextColorHex: nil,
        fontSelection: .system
    )

    init(
        selectedBookIDs: [Int64],
        selectedTagIDs: [Int64],
        tagMatchRule: NoteReviewTagMatchRule,
        sortRule: NoteReviewSortRule,
        palette: NoteReviewPalette,
        textAlignment: NoteReviewTextAlignment,
        backgroundMode: NoteReviewBackgroundMode,
        backgroundImageURL: String?,
        customBackgroundStartHex: UInt32?,
        customBackgroundEndHex: UInt32?,
        customTextColorHex: UInt32?,
        fontSelection: NoteReviewFontSelection
    ) {
        self.selectedBookIDs = selectedBookIDs
        self.selectedTagIDs = selectedTagIDs
        self.tagMatchRule = tagMatchRule
        self.sortRule = sortRule
        self.palette = palette.canonicalPalette
        self.textAlignment = textAlignment
        self.backgroundMode = backgroundMode
        self.backgroundImageURL = backgroundImageURL
        self.customBackgroundStartHex = customBackgroundStartHex
        self.customBackgroundEndHex = customBackgroundEndHex
        self.customTextColorHex = customTextColorHex
        self.fontSelection = fontSelection
    }

    /// 兼容旧版本只保存范围与配色的设置数据，新字段缺失时回退到 Android 默认语义。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedBookIDs = try container.decodeIfPresent([Int64].self, forKey: .selectedBookIDs) ?? []
        selectedTagIDs = try container.decodeIfPresent([Int64].self, forKey: .selectedTagIDs) ?? []
        tagMatchRule = try container.decodeIfPresent(NoteReviewTagMatchRule.self, forKey: .tagMatchRule) ?? .any
        sortRule = try container.decodeIfPresent(NoteReviewSortRule.self, forKey: .sortRule) ?? .random
        palette = (try container.decodeIfPresent(NoteReviewPalette.self, forKey: .palette) ?? .paper).canonicalPalette
        textAlignment = try container.decodeIfPresent(NoteReviewTextAlignment.self, forKey: .textAlignment) ?? .leading
        backgroundMode = try container.decodeIfPresent(NoteReviewBackgroundMode.self, forKey: .backgroundMode) ?? .color
        backgroundImageURL = try container.decodeIfPresent(String.self, forKey: .backgroundImageURL)
        customBackgroundStartHex = try container.decodeIfPresent(UInt32.self, forKey: .customBackgroundStartHex)
        customBackgroundEndHex = try container.decodeIfPresent(UInt32.self, forKey: .customBackgroundEndHex)
        customTextColorHex = try container.decodeIfPresent(UInt32.self, forKey: .customTextColorHex)
        fontSelection = try container.decodeIfPresent(NoteReviewFontSelection.self, forKey: .fontSelection) ?? .system
    }

    /// 当前有效背景起止颜色，图片背景不可用时也作为稳定回退颜色。
    /// 返回自定义值优先、否则回退到规范化配色浅色背景的起始色。
    var effectiveBackgroundStartHex: UInt32 {
        customBackgroundStartHex ?? palette.defaultBackgroundStartHex
    }

    /// 返回自定义值优先、否则回退到规范化配色浅色背景的终止色。
    var effectiveBackgroundEndHex: UInt32 {
        customBackgroundEndHex ?? palette.defaultBackgroundEndHex
    }

    /// 返回浅色外观下当前背景模式应使用的文本色；自定义文字色仅在图片模式生效。
    var effectiveTextColorHex: UInt32 {
        cardTextHex(isDarkAppearance: false)
    }

    /// 按显式亮暗外观返回卡片表面色；颜色模式兼容历史自定义背景，但不再生成渐变。
    func cardSurfaceHex(isDarkAppearance: Bool) -> UInt32 {
        guard backgroundMode == .color,
              let customSurfaceHex = customBackgroundStartHex ?? customBackgroundEndHex else {
            return palette.cardColorSet.surfaceHex(isDarkAppearance: isDarkAppearance)
        }
        return customSurfaceHex
    }

    /// 按显式亮暗外观返回卡片文字色；颜色模式固定使用 palette 的 on-surface，保留图片模式的自定义文字色。
    func cardTextHex(isDarkAppearance: Bool) -> UInt32 {
        guard backgroundMode == .image,
              let customTextColorHex else {
            return palette.cardColorSet.textHex(isDarkAppearance: isDarkAppearance)
        }
        return customTextColorHex
    }

    /// 判断设置变化是否会改变数据库查询结果，用于区分重载和纯外观刷新。
    func hasSameDataScope(as other: NoteReviewSettings) -> Bool {
        selectedBookIDs == other.selectedBookIDs
            && selectedTagIDs == other.selectedTagIDs
            && tagMatchRule == other.tagMatchRule
            && sortRule == other.sortRule
    }
}

/// 书摘回顾分页请求上下文，隔离顺序分页和随机排除两种读取参数。
nonisolated struct NoteReviewPageRequest: Hashable, Sendable {
    let settings: NoteReviewSettings
    let offset: Int
    let excludedNoteIDs: [Int64]
    let limit: Int
}

/// 回顾卡片展示项，保留卡堆、标签区与详情跳转所需的稳定字段。
nonisolated struct NoteReviewCardItem: Identifiable, Sendable {
    let id: Int64
    let bookID: Int64
    let bookTitle: String
    let bookAuthor: String
    let bookCoverURL: String
    let chapterTitle: String
    let contentHTML: String
    let ideaHTML: String
    let position: String
    let positionUnit: Int64
    let includeTime: Bool
    let createdDate: Int64
    let imageURLs: [String]
    let tags: [NoteEditorTagOption]
    let weReadOriginalURL: String?

    /// 返回仅替换标签集合的新卡片，用于回顾页标签编辑保存后的本地同步。
    func replacingTags(_ nextTags: [NoteEditorTagOption]) -> NoteReviewCardItem {
        NoteReviewCardItem(
            id: id,
            bookID: bookID,
            bookTitle: bookTitle,
            bookAuthor: bookAuthor,
            bookCoverURL: bookCoverURL,
            chapterTitle: chapterTitle,
            contentHTML: contentHTML,
            ideaHTML: ideaHTML,
            position: position,
            positionUnit: positionUnit,
            includeTime: includeTime,
            createdDate: createdDate,
            imageURLs: imageURLs,
            tags: nextTags,
            weReadOriginalURL: weReadOriginalURL
        )
    }
}

/// 回顾设置中的书摘标签选项，带计数用于辅助用户理解筛选范围。
nonisolated struct NoteReviewTagOption: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
    let noteCount: Int
}

/// 当前回顾卡片编辑标签所需的完整标签快照。
nonisolated struct NoteReviewTagEditSnapshot: Sendable {
    let availableTags: [NoteEditorTagOption]
    let selectedTags: [NoteEditorTagOption]
}
