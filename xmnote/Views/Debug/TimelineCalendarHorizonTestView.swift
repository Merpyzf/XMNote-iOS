#if DEBUG
/**
 * [INPUT]: 依赖 ReadingTimelineView 正式时间线页面
 * [OUTPUT]: 对外提供 TimelineCalendarHorizonTestView（时间线日历调试壳页）
 * [POS]: Debug 测试入口，复用正式时间线实现用于回归验证，避免双份逻辑分叉
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线日历调试壳页：直接复用首页时间线模块。
struct TimelineCalendarHorizonTestView: View {
    var body: some View {
        ReadingTimelineView()
            .navigationTitle("时间线日历-Horizon")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        TimelineCalendarHorizonTestView()
    }
}
#endif
