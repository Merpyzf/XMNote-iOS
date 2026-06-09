/**
 * [INPUT]: 依赖 SwiftUI ButtonStyle 配置书籍搜索相关胶囊按钮的按压态
 * [OUTPUT]: 对外提供 BookSearchChipButtonStyle，统一书籍搜索来源与选书器来源胶囊的轻量反馈
 * [POS]: Book 模块页面私有按钮样式，被 BookSearchView 与 BookPickerView 的搜索来源胶囊复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍搜索胶囊按钮样式，提供轻量按压反馈，避免和结果卡片的按压感冲突。
struct BookSearchChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.smooth(duration: 0.16), value: configuration.isPressed)
    }
}
