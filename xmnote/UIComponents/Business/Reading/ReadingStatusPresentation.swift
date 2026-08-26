/**
 * [INPUT]: 依赖 SwiftUI Color 与集中式颜色构造能力，接收 Android 对齐的阅读状态 ID
 * [OUTPUT]: 对外提供 ReadingStatusPresentation 五种阅读状态颜色及可失败的 ID 映射
 * [POS]: UIComponents/Business/Reading 的跨模块阅读状态视觉 owner，供书架、时间线、热力图与阅读详情复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 将稳定的阅读状态业务 ID 映射为展示色；未知状态由调用页面保留各自既有 fallback。
enum ReadingStatusPresentation {
    static let wantRead = Color.xmHex(0xEF5350)
    static let reading = Color.xmHex(0x42A5F5)
    static let readDone = Color.xmHex(0xFFB600)
    static let abandoned = Color.xmHex(0x9E9E9E)
    static let onHold = Color.xmHex(0xAB47BC)

    /// 返回已知阅读状态的颜色；未知 ID 返回 nil，避免抹平页面原有的未知态语义。
    static func color(for statusID: Int64) -> Color? {
        switch statusID {
        case 1: wantRead
        case 2: reading
        case 3: readDone
        case 4: abandoned
        case 5: onHold
        default: nil
        }
    }
}
