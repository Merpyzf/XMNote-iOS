/**
 * [INPUT]: 依赖 RichTextFormat 与 Foundation，承接外部浮动挂饰工具栏和 UIKit 编辑器之间的命令桥接
 * [OUTPUT]: 对外提供 RichTextToolbarCommand、RichTextOrnamentController
 * [POS]: RichTextEditor 功能模块内部状态桥接器，用于全屏编辑页的浮动液态玻璃工具栏模式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 富文本外部挂饰工具栏可触发的命令集合。
@MainActor
enum RichTextToolbarCommand {
    case toggleFormat(RichTextFormat)
    case clearFormats
    case undo
    case redo
    case moveCursorLeft
    case moveCursorRight
    case indent
    case focus
    case moveCursorToEnd
    case insertText(String)
    case cameraTextCapture
    case dismissKeyboard
}

/// 富文本浮动挂饰控制器，负责把 SwiftUI 工具栏状态与 UIKit 编辑器能力桥接起来。
@MainActor
@Observable
final class RichTextOrnamentController {
    var activeFormats: Set<RichTextFormat> = []
    var hasSelection = false
    var canUndo = false
    var canRedo = false
    var canCaptureTextFromCamera = false
    var isFocused = false

    var commandHandler: ((RichTextToolbarCommand) -> Void)?

    /// 透传工具栏命令到当前挂接的编辑器实例。
    func send(_ command: RichTextToolbarCommand) {
        commandHandler?(command)
    }
}
