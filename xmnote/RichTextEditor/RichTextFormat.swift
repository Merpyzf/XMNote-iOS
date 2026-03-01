/**
 * [INPUT]: 依赖 RichTextEditor 模块格式定义与 UIKit/TextKit 能力，承接富文本解析/渲染/编辑链路
 * [OUTPUT]: 对外提供 RichTextFormat 能力，用于富文本编辑器的序列化、交互或样式支持
 * [POS]: RichTextEditor 功能模块内部构件，服务 Note 编辑场景的 Android 业务意图对齐
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

// MARK: - 格式枚举

/// 对标 Knife FORMAT_* 常量，定义 8 种富文本格式
enum RichTextFormat: CaseIterable {
    case bold
    case italic
    case underline
    case strikethrough
    case highlight
    case bulletList
    case blockquote
    case link
}

// MARK: - 自定义属性键

extension NSAttributedString.Key {
    /// 段落级：无序列表标记
    static let bulletList = NSAttributedString.Key("xmnote.bulletList")
    /// 段落级：引用块标记
    static let blockquote = NSAttributedString.Key("xmnote.blockquote")
    /// 存储 light mode 原始色值（UInt32），确保序列化时跨平台一致
    static let highlightColor = NSAttributedString.Key("xmnote.highlightColor")
    /// CJK 字体 oblique 斜体标记（无原生 italic 变体时使用）
    static let obliqueItalic = NSAttributedString.Key("xmnote.obliqueItalic")
}
