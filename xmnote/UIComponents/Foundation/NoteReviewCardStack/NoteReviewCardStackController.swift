/**
 * [INPUT]: 依赖 Observation 状态追踪与 NoteReviewCardStackDirection/RefreshMode 命令参数
 * [OUTPUT]: 对外提供 NoteReviewCardStackController，统一驱动程序化滑动、撤回、重载、刷新与位置跳转
 * [POS]: NoteReviewCardStack 的命令与状态中枢，供 Debug 页和后续正式书摘回顾页持有
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 书摘回顾卡堆刷新语义，区分回到首张与重新洗牌两类动效。
enum NoteReviewCardStackRefreshMode: Hashable {
    case ordered
    case shuffled
}

/// 控制书摘回顾卡堆的程序化动作，并向 SwiftUI 暴露当前卡片状态。
@MainActor
@Observable
final class NoteReviewCardStackController {
    enum Command: Equatable {
        case swipe(id: UUID, direction: NoteReviewCardStackDirection, animated: Bool)
        case rewind(id: UUID, animated: Bool)
        case reload(id: UUID, keepingPosition: Bool)
        case refresh(id: UUID, mode: NoteReviewCardStackRefreshMode)
        case scrollToIndex(id: UUID, index: Int, animated: Bool)
        case scrollToFirst(id: UUID, animated: Bool)

        var id: UUID {
            switch self {
            case let .swipe(id, _, _),
                 let .rewind(id, _),
                 let .reload(id, _),
                 let .refresh(id, _),
                 let .scrollToIndex(id, _, _),
                 let .scrollToFirst(id, _):
                return id
            }
        }
    }

    private(set) var currentIndex: Int?
    private(set) var appearedIndex: Int?
    private(set) var disappearedIndex: Int?
    private(set) var isAnimating = false
    private(set) var isRefreshing = false
    private(set) var pendingCommand: Command?

    /// 请求向指定方向翻到下一张；四个方向当前均为“下一条”语义。
    func swipe(
        direction: NoteReviewCardStackDirection = .right,
        animated: Bool = true
    ) {
        pendingCommand = .swipe(id: UUID(), direction: direction, animated: animated)
    }

    /// 请求撤回最近一次滑走的卡片。
    func rewind(animated: Bool = true) {
        pendingCommand = .rewind(id: UUID(), animated: animated)
    }

    /// 请求重载卡堆，可选择保持当前 top index。
    func reload(keepingPosition: Bool = true) {
        pendingCommand = .reload(id: UUID(), keepingPosition: keepingPosition)
    }

    /// 请求执行带结构动效的刷新；执行期间会阻止重复刷新与其他程序化命令。
    func refresh(mode: NoteReviewCardStackRefreshMode) {
        guard !isRefreshing else { return }
        isRefreshing = true
        pendingCommand = .refresh(id: UUID(), mode: mode)
    }

    /// 请求跳转到指定数据源索引。
    func scrollToIndex(_ index: Int, animated: Bool = true) {
        pendingCommand = .scrollToIndex(id: UUID(), index: index, animated: animated)
    }

    /// 请求回到第一张卡片。
    func scrollToFirst(animated: Bool = true) {
        pendingCommand = .scrollToFirst(id: UUID(), animated: animated)
    }

    func clearCommand(_ commandID: UUID) {
        guard pendingCommand?.id == commandID else { return }
        pendingCommand = nil
    }

    func update(
        currentIndex: Int?,
        appearedIndex: Int?,
        disappearedIndex: Int?,
        isAnimating: Bool
    ) {
        if self.currentIndex != currentIndex {
            self.currentIndex = currentIndex
        }
        if self.appearedIndex != appearedIndex {
            self.appearedIndex = appearedIndex
        }
        if self.disappearedIndex != disappearedIndex {
            self.disappearedIndex = disappearedIndex
        }
        if self.isAnimating != isAnimating {
            self.isAnimating = isAnimating
        }
    }

    func finishRefresh() {
        guard isRefreshing else { return }
        isRefreshing = false
    }
}
