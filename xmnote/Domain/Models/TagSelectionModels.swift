/**
 * [INPUT]: 无外部依赖
 * [OUTPUT]: 对外提供 TagSelectionLayoutMode，描述通用标签选择器的列表与双列网格展示偏好
 * [POS]: Domain/Models 的标签选择展示模型，由 UI 与偏好 Repository 共同使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 通用标签选择器的展示方式；网格语义固定为双列，具体列配置由共享组件负责。
nonisolated enum TagSelectionLayoutMode: String, CaseIterable, Hashable, Sendable {
    case list
    case grid

    var title: String {
        switch self {
        case .list:
            return "列表"
        case .grid:
            return "网格"
        }
    }

    var systemImage: String {
        switch self {
        case .list:
            return "list.bullet"
        case .grid:
            return "square.grid.2x2"
        }
    }
}
