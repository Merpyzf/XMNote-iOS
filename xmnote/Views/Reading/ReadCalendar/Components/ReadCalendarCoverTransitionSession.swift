/**
 * [INPUT]: 依赖 SwiftUI 几何类型，接收日格源位 frame 与源封面尺寸
 * [OUTPUT]: 对外提供 ReadCalendarCoverTransitionSession（封面过渡会话上下文）
 * [POS]: ReadCalendar 页面私有数据模型，用于在点击日格与弹层舞台之间传递空间锚点
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// ReadCalendarCoverTransitionSession 记录一次封面过渡所需的源位置信息。
struct ReadCalendarCoverTransitionSession: Hashable {
    let sourceStackFrame: CGRect?
    let sourceCoverSize: CGSize

    /// 创建封面过渡会话：sourceStackFrame 可空，空值时走中心降级过渡。
    init(sourceStackFrame: CGRect?, sourceCoverSize: CGSize) {
        self.sourceStackFrame = sourceStackFrame
        self.sourceCoverSize = sourceCoverSize
    }
}
