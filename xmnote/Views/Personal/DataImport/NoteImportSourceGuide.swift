/**
 * [INPUT]: 依赖 NoteImportParserID 与已核对的 Android 导入手册来源步骤
 * [OUTPUT]: 提供输入页插画、无歧义的平台身份、两步准备说明、文件类型、来源分组及详细帮助链接
 * [POS]: Views/Personal/DataImport 的功能私有来源配置，不改变 Parser 检测优先级
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UniformTypeIdentifiers

/// 输入方式与允许的解析器集合，共享同一准备、检查、预览流程。
nonisolated enum NoteImportSourceInput: Sendable {
    case file(parserID: NoteImportParserID?)
    case fileCandidates([NoteImportParserID])
    case clipboard(parserID: NoteImportParserID)
    case clipboardCandidates([NoteImportParserID])

    var isFile: Bool {
        switch self {
        case .file, .fileCandidates: true
        case .clipboard, .clipboardCandidates: false
        }
    }

    var parserIDs: [NoteImportParserID] {
        switch self {
        case .file(let id): id.map { [$0] } ?? []
        case .clipboard(let id): [id]
        case .fileCandidates(let ids), .clipboardCandidates(let ids): ids
        }
    }
}

/// 来源文案只描述用户操作；没有可靠手册的来源不猜测第三方菜单路径。
struct NoteImportSourceGuide {
    let title: String
    let input: NoteImportSourceInput

    var heading: String { input.isFile ? "导入笔记文件" : "从剪贴板导入" }
    var helpTitle: String { input.isFile ? "如何导出笔记" : "如何复制笔记" }
    var primaryTitle: String { input.isFile ? "选择文件" : "读取剪贴板" }

    var platform: NoteImportPlatform? {
        let platforms = input.parserIDs.map { NoteImportPlatform(parserID: $0) }
        guard let first = platforms.first, let platform = first,
              platforms.allSatisfy({ $0 == platform }) else { return nil }
        return platform
    }

    var illustration: NoteImportIllustration {
        guard input.isFile else { return .clipboard }
        return switch input.parserIDs.first {
        case .legado, .neatReader, .koreader, .reeden: .json
        case .booxOld, .booxNew, .doubanRead, .kindle: .txt
        case .koodo: .csv
        case .appleBooks: .zip
        case .ireaderEpub: .epub
        case .kindleApp: .html
        case .dimo: .md
        default: .file
        }
    }

    var subtitle: String {
        input.isFile ? "支持 \(format)，可选择多个同来源文件" : "复制完整笔记，保留书籍信息"
    }

    var preparationSteps: [NoteImportPreparationStep] {
        [
            .init(title: input.isFile ? "导出笔记" : "复制笔记", detail: preparationSummary),
            .init(
                title: input.isFile ? "保存并选择文件" : "读取并检查原文",
                detail: input.isFile
                    ? "保存到 iPhone 或 iPad 的“文件”中，再回到这里选择。"
                    : "返回这里读取剪贴板，必要时查看和编辑原文。"
            )
        ]
    }

    private var preparationSummary: String {
        switch input.parserIDs.first {
        case .legado: "在阅读的“个人 → 书签”中，选择菜单中的“导出”。"
        case .appleBooks: "在 Mac 上取得批注与书库数据，打包为一个 ZIP 文件。"
        case .koodo: "从 Koodo Reader 导出 CSV，保留完整的高亮和笔记。"
        default: input.isFile ? "从\(title)导出原始笔记，保留文件格式与内容。" : "在\(title)中复制笔记，保留书名与来源标记。"
        }
    }

    var preparation: String {
        switch input.parserIDs.first {
        case .legado: "在阅读 App 的“个人 → 书签”中，打开右上角菜单并选择“导出”。"
        case .wereadOld, .wereadPre830, .weread830: "在微信读书的“我的 → 笔记”中，选择书籍并复制需要导入的笔记。"
        case .doubanRead: "在豆瓣阅读网页版打开书籍的“批注和划线”，选择“导出所有笔记”，勾选纯文本后下载。"
        case .koreader: "在 KOReader 中将笔记导出为 JSON，支持“导出本书笔记”和“导出所有笔记”。"
        case .koodo: "在 Koodo Reader 中选择书籍的“导出笔记”，保存为 CSV 文件。"
        case .appleBooks: "在 Mac 上取得 Apple Books 的批注与书库数据，将两者打包为一个 ZIP 文件。"
        case .ireaderFile: "在掌阅的“我的 → 笔记”中选择书籍，点击“导出”，再选择“导出到本地”。"
        case .jdReader: "在京东读书的“我的 → 读书记录 → 想法”中选择书籍，全选笔记并导出至本地。"
        case .duokan: "在多看阅读的“我的 → 想法”中选择书籍，依次选择“导出 → 其他 → 复制”。"
        case .moonReader: "在静读天下的阅读页打开“目录 → 书签 → 分享”，选择“分享高亮与备注（TXT）”并复制。"
        case .ireaderSelected: "在掌阅精选的“我的 → 笔记”中选择书籍，导出笔记并选择“复制到剪贴板”。"
        case .doubanApp: "在豆瓣阅读 App 的“我的 → 笔记”中选择书籍，点击右上角导出按钮，再选择复制。"
        case .reader163: "在网易蜗牛的阅读页点击“批”，进入批注管理后选择右上角“导出批注”。"
        case .fanqie: "在番茄小说的“我的 → 我的笔记”中选择书籍，点击“管理 → 全选 → 复制”。"
        default: input.isFile
            ? "从\(title)导出原始笔记文件，不要修改文件格式或后缀。"
            : "在\(title)中复制需要导入的笔记，保留完整的书籍信息与来源标记。"
        }
    }

    var steps: [String] {
        [preparation,
         input.isFile ? "将文件保存到 iPhone 或 iPad 的“文件”中，再回到这里选择。" : "返回这里读取剪贴板，必要时查看和编辑原文。",
         "先预览书摘，检查书籍与内容后再确认导入。"]
    }

    var format: String {
        switch input.parserIDs.first {
        case .legado, .neatReader, .koreader, .reeden: "JSON"
        case .koodo: "CSV"
        case .appleBooks: "ZIP"
        case .ireaderEpub: "EPUB"
        case .kindleApp: "HTML"
        case .booxOld, .booxNew, .doubanRead, .kindle: "TXT"
        default: "原始笔记文件"
        }
    }

    var contentTypes: [UTType] {
        switch format {
        case "JSON": [.json]
        case "CSV": [.commaSeparatedText]
        case "ZIP": [.zip]
        case "EPUB": [.epub]
        case "HTML": [.html]
        case "TXT": [.plainText]
        default: [.data]
        }
    }

    var caution: String {
        switch input.parserIDs.first {
        case .appleBooks: "需要同时包含 AEAnnotation 与 BKLibrary 的数据文件，不是电子书文件。只支持 ZIP 压缩格式。"
        case .koodo: "单本书的“导出笔记”包含高亮和笔记。导出全部书籍时，需要分别导出所有笔记和所有高亮，避免遗漏内容。"
        case .jdReader: "京东读书文件中的章节信息会作为摘录导入。"
        default: input.isFile ? "可以选择多个文件，但每批只能包含同一来源的笔记。" : "请保留书名、分隔符和来源标记，以免影响识别。"
        }
    }

    var additionalDetails: [String] {
        switch input.parserIDs.first {
        case .appleBooks:
            ["在 Mac 的访达中前往 ~/Library/Containers/com.apple.iBooksX/Data/Documents/AEAnnotation，取得批注数据。",
             "再前往 ~/Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary，取得书库数据。",
             "将两个目录中的数据文件放到同一文件夹，压缩为 ZIP 后发送到 iPhone 或 iPad。"]
        case .ireaderFile: ["Android 掌阅通常将导出的文件保存在 /iReader/NoteBook/。请先将文件传输到当前设备。"]
        case .booxOld, .booxNew: ["从 BOOX 导出笔记后，将导出的文本文件从阅读器传输到当前设备。支持同一批次选择新旧导出格式。"]
        default: []
        }
    }

    var manualURL: URL? {
        let page = input.isFile ? "file" : "clipboard"
        let section: String? = switch input.parserIDs.first {
        case .legado: "从「阅读」导入"
        case .wereadOld, .wereadPre830, .weread830: "从「微信读书」导入"
        case .koreader: "从「koreader」导入"
        case .booxOld, .booxNew: "从「boox（文石）」导入"
        case .appleBooks: "从「apple-books」导入"
        case .koodo: "从-koodo-reader-导入"
        case .doubanRead: "从「豆瓣阅读（网页版）」导入"
        case .jdReader: "从「京东读书」导入"
        case .ireaderFile: "从「掌阅」导入"
        case .neatReader: "从-「neatreader」导入"
        case .moonReader: "从「静读天下」导入"
        case .duokan: "从「多看阅读」导入"
        case .ireaderSelected: "从「掌阅精选」导入"
        case .doubanApp: "从「豆瓣阅读-app」导入"
        case .reader163: "从「网易蜗牛」导入"
        case .fanqie: "从-「番茄免费小说」导入"
        default: nil
        }
        let suffix = section.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }.map { "?id=\($0)" } ?? ""
        return URL(string: "https://docs.xmnote.com/#/import/\(page)\(suffix)")
    }
}

extension NoteImportParserID {
    /// 多个导出版本属于同一来源，批次约束不以解析器版本或文件扩展名划分。
    nonisolated var importSourceFamily: NoteImportParserID {
        switch self {
        case .booxOld, .booxNew: .booxNew
        case .wereadOld, .wereadPre830, .weread830: .weread830
        default: self
        }
    }
}
