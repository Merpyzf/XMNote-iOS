#if DEBUG
/**
 * [INPUT]: 依赖 Foundation/CoreGraphics 与 NoteReviewPagingDeckConfiguration 组织调试场景、分页状态、刷新模式与事件日志
 * [OUTPUT]: 对外提供 NoteReviewPagingTestViewModel 与 NoteReviewPagingSampleNote，支持 BigUIPaging Core + XMNote 自定义书摘回顾卡组验证
 * [POS]: Debug 模块书摘回顾分页卡组测试页状态编排，隔离 mock 数据、调参项与交互事件记录
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreGraphics
import Foundation

struct NoteReviewPagingSampleNote: Identifiable, Equatable {
    enum Kind: String {
        case text
        case longText
        case imageOnly
        case ideaOnly
        case tagsOnly
    }

    let id: UUID
    let kind: Kind
    let content: String
    let idea: String
    let bookTitle: String
    let tags: [String]
    let palette: NoteReviewPagingSamplePalette
}

struct NoteReviewPagingSamplePalette: Equatable {
    let backgroundHex: UInt
    let accentHex: UInt
}

@MainActor
@Observable
final class NoteReviewPagingTestViewModel {
    enum Scenario: String, CaseIterable, Identifiable {
        case empty
        case single
        case triple
        case longScroll
        case imageOnly
        case twentyWithPreload

        var id: String { rawValue }

        var title: String {
            switch self {
            case .empty:
                return "空态"
            case .single:
                return "单卡"
            case .triple:
                return "三卡"
            case .longScroll:
                return "长文滚动"
            case .imageOnly:
                return "图片-only"
            case .twentyWithPreload:
                return "分页模拟"
            }
        }
    }

    var scenario: Scenario = .triple
    var notes: [NoteReviewPagingSampleNote] = []
    var selectedNoteID: UUID?
    var configuration = NoteReviewPagingDeckConfiguration.iOSReviewDefault
    var eventLog: [String] = []
    var simulatedPage = 1
    var hasMoreItems = false
    var isReduceMotionPreviewEnabled = false

    init() {
        applyScenario(.triple)
    }

    var currentIndex: Int? {
        guard let selectedNoteID else { return nil }
        return notes.firstIndex { $0.id == selectedNoteID }
    }

    var stateText: String {
        guard let currentIndex else { return notes.isEmpty ? "empty" : "未选中" }
        return "\(currentIndex + 1) / \(notes.count)"
    }

    /// 切换调试场景并重置分页、选中项与事件日志。
    func applyScenario(_ scenario: Scenario) {
        self.scenario = scenario
        simulatedPage = 1
        eventLog.removeAll()
        switch scenario {
        case .empty:
            notes = []
            hasMoreItems = false
        case .single:
            notes = [Self.makeNote(index: 1, kind: .text)]
            hasMoreItems = false
        case .triple:
            notes = (1...3).map { Self.makeNote(index: $0, kind: .text) }
            hasMoreItems = false
        case .longScroll:
            notes = [
                Self.makeNote(index: 1, kind: .longText),
                Self.makeNote(index: 2, kind: .text),
                Self.makeNote(index: 3, kind: .ideaOnly)
            ]
            hasMoreItems = false
        case .imageOnly:
            notes = [
                Self.makeNote(index: 1, kind: .imageOnly),
                Self.makeNote(index: 2, kind: .tagsOnly),
                Self.makeNote(index: 3, kind: .text)
            ]
            hasMoreItems = false
        case .twentyWithPreload:
            notes = (1...20).map { Self.makeNote(index: $0, kind: $0.isMultiple(of: 5) ? .longText : .text) }
            hasMoreItems = true
        }
        selectedNoteID = notes.first?.id
        appendLog("场景: \(scenario.title)")
    }

    /// 模拟分页追加，用于验证基础组件的 onNeedsMoreItems 信号与动态 next/previous。
    func appendSimulatedPage() {
        guard scenario == .twentyWithPreload, hasMoreItems else { return }
        simulatedPage += 1
        let start = notes.count + 1
        let end = start + 9
        notes.append(contentsOf: (start...end).map { Self.makeNote(index: $0, kind: .text) })
        hasMoreItems = simulatedPage < 3
        appendLog("追加第 \(simulatedPage) 页: \(start)-\(end)")
    }

    func navigate(_ navigation: NoteReviewPagingNavigation) {
        var state = NoteReviewPagingState(
            itemIDs: notes.map(\.id),
            selection: selectedNoteID,
            hasMoreItems: hasMoreItems,
            isLoopingEnabled: configuration.isLoopingEnabled
        )
        state.navigate(navigation)
        selectedNoteID = state.normalizedSelection
        appendLog(navigation == .next ? "程序切到下一张" : "程序切到上一张")
    }

    func resetConfiguration() {
        configuration = .iOSReviewDefault
        appendLog("重置参数")
    }

    func orderedRefresh() {
        selectedNoteID = notes.first?.id
        appendLog("顺序刷新")
    }

    func shuffledRefresh() {
        let originalIDs = notes.map(\.id)
        if notes.count > 1 {
            notes.shuffle()
            if notes.map(\.id) == originalIDs {
                notes.append(notes.removeFirst())
            }
        }
        selectedNoteID = notes.first?.id
        appendLog("乱序刷新")
    }

    func selectFirst() {
        selectedNoteID = notes.first?.id
        appendLog("回到首张")
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        eventLog.insert("\(formatter.string(from: Date()))  \(message)", at: 0)
        if eventLog.count > 80 {
            eventLog.removeLast(eventLog.count - 80)
        }
    }

    private static func makeNote(index: Int, kind: NoteReviewPagingSampleNote.Kind) -> NoteReviewPagingSampleNote {
        let palettes = [
            NoteReviewPagingSamplePalette(backgroundHex: 0xA9C8DE, accentHex: 0x3B5568),
            NoteReviewPagingSamplePalette(backgroundHex: 0xE7D8B8, accentHex: 0x735F3F),
            NoteReviewPagingSamplePalette(backgroundHex: 0xC7D9BF, accentHex: 0x466044),
            NoteReviewPagingSamplePalette(backgroundHex: 0xD7C6DF, accentHex: 0x60486B)
        ]
        let content: String
        let idea: String
        switch kind {
        case .text:
            content = "就像 C++ 的创造者本贾尼·斯特劳斯特鲁普曾说过的那样，如果把十年花在研究深奥的数学上，Unix 就会胎死腹中。"
            idea = "低阈值滑动适合轻量回顾，但卡内阅读必须优先保证稳定。"
        case .longText:
            content = Array(repeating: "阅读型卡片的第一职责不是被快速丢出去，而是让用户能安静看完。外层滑动要足够顺，但不能抢走内部滚动。", count: 10).joined(separator: "\n\n")
            idea = "这个场景用于验证 ScrollView 与外层卡组手势仲裁。"
        case .imageOnly:
            content = ""
            idea = ""
        case .ideaOnly:
            content = ""
            idea = "只有想法没有原文时，卡片仍应保持居中阅读节奏。"
        case .tagsOnly:
            content = "标签较多时底部信息不能挤压正文，也不能让卡片高度抖动。"
            idea = ""
        }
        return NoteReviewPagingSampleNote(
            id: UUID(),
            kind: kind,
            content: content,
            idea: idea,
            bookTitle: "《UNIX 传奇》#\(index)",
            tags: index.isMultiple(of: 4) ? [] : ["设计", "阅读", index.isMultiple(of: 2) ? "长摘录" : "回顾"],
            palette: palettes[(index - 1) % palettes.count]
        )
    }
}
#endif
