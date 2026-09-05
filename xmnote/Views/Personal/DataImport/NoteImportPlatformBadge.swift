/**
 * [INPUT]: 依赖角标专用原色资源、导入解析器身份与项目自适应表层令牌
 * [OUTPUT]: 提供导入功能私有的平台映射及同源内缩轮廓角标
 * [POS]: Views/Personal/DataImport 的插画附件，不持有输入或导航状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 平台身份与输入载体分离；同一平台的不同导出版本共用标志。
enum NoteImportPlatform: String {
    case kindle = "Kindle", weRead = "WeRead", legado = "Legado", appleBooks = "AppleBooks"
    case koReader = "KoReader", boox = "Boox", doubanRead = "DoubanRead", jdReader = "JdReader"
    case iReader = "IReader", neatReader = "NeatReader", koodoReader = "KoodoReader"
    case dimo = "Dimo", reeden = "Reeden", dedao = "Dedao", iReaderSelect = "IReaderSelect"
    case moonReader = "MoonReader", duokan = "Duokan", dangdang = "Dangdang"
    case doubanApp = "DoubanApp", neteaseSnail = "NeteaseSnail", fanqie = "Fanqie", readingo = "Readingo"

    var resourceName: String { "NoteImportPlatform" + rawValue }

    /// 仅映射已有输入页的平台；扫码来源不借用文件页身份。
    init?(parserID: NoteImportParserID) {
        switch parserID {
        case .kindle, .kindleApp: self = .kindle
        case .wereadOld, .wereadPre830, .weread830: self = .weRead
        case .booxOld, .booxNew: self = .boox
        case .legado: self = .legado
        case .appleBooks: self = .appleBooks
        case .koreader: self = .koReader
        case .doubanRead: self = .doubanRead
        case .jdReader: self = .jdReader
        case .ireaderFile, .ireaderEpub: self = .iReader
        case .neatReader: self = .neatReader
        case .koodo: self = .koodoReader
        case .dimo: self = .dimo
        case .reeden: self = .reeden
        case .dedao: self = .dedao
        case .ireaderSelected: self = .iReaderSelect
        case .moonReader: self = .moonReader
        case .duokan: self = .duokan
        case .dangdang: self = .dangdang
        case .doubanApp: self = .doubanApp
        case .reader163: self = .neteaseSnail
        case .fanqie: self = .fanqie
        case .readingo: self = .readingo
        case .hanwang: return nil
        }
    }
}

/// 装饰性平台角标；内外轮廓共享一个连续形状，避免资源自带圆角造成白边不均。
struct NoteImportPlatformBadge: View {
    let platform: NoteImportPlatform
    var isCompact = false

    /// 已确认方案 A 的附件几何，保持独立于页面留白与动态文字尺寸。
    private enum Metrics {
        static let regularSize: CGFloat = 32
        static let compactSize: CGFloat = 24
        static let outerRadius: CGFloat = 9
        static let inset: CGFloat = 2
    }

    private var size: CGFloat { isCompact ? Metrics.compactSize : Metrics.regularSize }
    private var inset: CGFloat { Metrics.inset }
    private var outline: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.outerRadius * size / Metrics.regularSize, style: .continuous)
    }

    var body: some View {
        outline
            .fill(Color.surfaceCard)
            .shadow(color: .black.opacity(0.16), radius: 2, y: 2)
            .overlay {
                Image(platform.resourceName)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .padding(inset)
                    .clipShape(outline.inset(by: inset))
            }
            .overlay {
                outline.strokeBorder(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
            }
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview("平台角标 · 两种尺寸") {
    VStack(spacing: Spacing.section) {
        ForEach([NoteImportPlatform.kindle, .weRead, .appleBooks, .koReader, .neatReader, .reeden], id: \.self) { platform in
            HStack(spacing: Spacing.section) {
                NoteImportPlatformBadge(platform: platform)
                NoteImportPlatformBadge(platform: platform, isCompact: true)
            }
        }
    }
    .padding(Spacing.screenEdge)
    .background(Color.surfacePage)
}
