#if DEBUG
/**
 * [INPUT]: 依赖 Foundation 管理搜索历史组件测试场景、样本关键词与交互日志
 * [OUTPUT]: 对外提供 SearchHistoryTestScenario、SearchHistoryTestViewModel，驱动测试中心搜索历史组件场景矩阵
 * [POS]: Debug 模块搜索历史测试页状态编排，隔离样本切换、单删、清空、展开与回调观测
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 搜索历史组件测试场景，覆盖空态、短词噪声、常规混合、超长词与满容量折叠。
enum SearchHistoryTestScenario: String, CaseIterable, Identifiable {
    case emptyHidden
    case emptyMessage
    case shortNoise
    case mixed
    case longKeyword
    case fullCapacity
    case interaction

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emptyHidden:
            return "无历史隐藏"
        case .emptyMessage:
            return "显式空态"
        case .shortNoise:
            return "短词噪声"
        case .mixed:
            return "常规混合"
        case .longKeyword:
            return "超长词"
        case .fullCapacity:
            return "8 条满容量"
        case .interaction:
            return "交互回调"
        }
    }

    var subtitle: String {
        switch self {
        case .emptyHidden:
            return "验证无历史时不渲染组件"
        case .emptyMessage:
            return "验证空态高度与说明层级"
        case .shortNoise:
            return "验证短词不会被拉成竖向胶囊"
        case .mixed:
            return "验证中文、英文、ISBN 与书名号混排"
        case .longKeyword:
            return "验证单个长词截断且不撑破容器"
        case .fullCapacity:
            return "验证两行折叠、更多与收起"
        case .interaction:
            return "验证点击、单删、清空与日志"
        }
    }

    var sampleQueries: [String] {
        switch self {
        case .emptyHidden, .emptyMessage:
            return []
        case .shortNoise:
            return ["w", "wi", "wo", "AI", "我"]
        case .mixed:
            return ["三体", "AI", "9787536692930", "《长安的荔枝》", "Cal Newport", "时间管理", "读书笔记"]
        case .longKeyword:
            return ["这是一条非常长的搜索关键词用于验证胶囊截断和容器边界", "超长作者名与副标题组合测试", "978-7-5442-7427-2"]
        case .fullCapacity:
            return ["原则", "复盘", "费曼学习法", "写作", "心理学", "SwiftUI", "阅读计划", "项目管理"]
        case .interaction:
            return ["最近打开", "删除我", "清空全部", "再次搜索", "长按菜单不依赖"]
        }
    }
}

/// 搜索历史组件测试页状态源，所有样本只存在内存中，不读写真实搜索历史。
@Observable
final class SearchHistoryTestViewModel {
    var scenario: SearchHistoryTestScenario = .shortNoise {
        didSet {
            guard scenario != oldValue else { return }
            applyScenario()
        }
    }
    var queries: [String] = SearchHistoryTestScenario.shortNoise.sampleQueries
    var isExpanded = false
    var isEditing = false
    var selectedQuery: String?
    var eventLog: [String] = []

    /// 重置当前场景样本，便于反复验证删除与清空后的恢复路径。
    func resetScenario() {
        applyScenario()
    }

    /// 记录点击搜索词回调，不触发真实搜索。
    func select(_ query: String) {
        selectedQuery = query
        appendLog("点击搜索词：\(query)")
    }

    /// 删除单条样本搜索词，并记录组件回调。
    func remove(_ query: String) {
        queries.removeAll { $0 == query }
        appendLog("删除搜索词：\(query)")
    }

    /// 清空当前样本搜索词，并回到折叠态。
    func clearAll() {
        queries = []
        isExpanded = false
        isEditing = false
        appendLog("清空全部搜索历史")
    }

    /// 记录测试页外部编辑状态变化，便于验证组件浏览/编辑模式回调与动画。
    func recordEditingChange(_ isEditing: Bool) {
        appendLog(isEditing ? "进入编辑模式" : "退出编辑模式")
    }

    private func applyScenario() {
        queries = scenario.sampleQueries
        isExpanded = false
        isEditing = false
        selectedQuery = nil
        appendLog("切换场景：\(scenario.title)")
    }

    private func appendLog(_ message: String) {
        eventLog.insert(message, at: 0)
        if eventLog.count > 12 {
            eventLog.removeLast(eventLog.count - 12)
        }
    }
}
#endif
