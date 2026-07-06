#if DEBUG
/**
 * [INPUT]: 依赖 Foundation/CoreGraphics 与 NoteReviewCardStackConfiguration 组织调试场景、参数、刷新模式与事件日志
 * [OUTPUT]: 对外提供 NoteReviewCardStackTestViewModel 与 NoteReviewCardStackSampleNote，支持书摘卡堆三段式刷新验证
 * [POS]: Debug 模块书摘回顾卡堆测试页状态编排，隔离 mock 数据、调参项与交互事件记录
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreGraphics
import Foundation

struct NoteReviewCardStackSampleNote: Identifiable, Equatable {
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
    let palette: NoteReviewCardStackSamplePalette
}

struct NoteReviewCardStackSamplePalette: Equatable {
    let backgroundHex: UInt
    let accentHex: UInt
}

@MainActor
@Observable
final class NoteReviewCardStackTestViewModel {
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
    var notes: [NoteReviewCardStackSampleNote] = []
    var configuration = NoteReviewCardStackConfiguration.iOSReviewDefault
    var selectedSwipeDirection: NoteReviewCardStackDirection = .right
    var eventLog: [String] = []
    var simulatedPage = 1

    init() {
        applyScenario(.triple)
    }

    /// 切换调试场景并重置分页与事件日志。
    func applyScenario(_ scenario: Scenario) {
        self.scenario = scenario
        simulatedPage = 1
        eventLog.removeAll()
        switch scenario {
        case .empty:
            notes = []
        case .single:
            notes = [Self.makeNote(index: 1, kind: .text)]
        case .triple:
            notes = (1...3).map { Self.makeNote(index: $0, kind: .text) }
        case .longScroll:
            notes = [
                Self.makeNote(index: 1, kind: .longText),
                Self.makeNote(index: 2, kind: .text),
                Self.makeNote(index: 3, kind: .ideaOnly)
            ]
        case .imageOnly:
            notes = [
                Self.makeNote(index: 1, kind: .imageOnly),
                Self.makeNote(index: 2, kind: .tagsOnly),
                Self.makeNote(index: 3, kind: .text)
            ]
        case .twentyWithPreload:
            notes = (1...20).map { Self.makeNote(index: $0, kind: $0.isMultiple(of: 5) ? .longText : .text) }
        }
        appendLog("场景: \(scenario.title)")
    }

    /// 模拟分页追加，用于验证基础组件的 onNeedsMoreItems 信号。
    func appendSimulatedPage() {
        guard scenario == .twentyWithPreload else { return }
        simulatedPage += 1
        let start = notes.count + 1
        let end = start + 9
        notes.append(contentsOf: (start...end).map { Self.makeNote(index: $0, kind: .text) })
        appendLog("追加第 \(simulatedPage) 页: \(start)-\(end)")
    }

    func resetConfiguration() {
        configuration = .iOSReviewDefault
        appendLog("重置参数")
    }

    func logOrderedRefresh() {
        appendLog("顺序刷新")
    }

    func shuffleNotesForRefresh() {
        let originalIDs = notes.map(\.id)
        if notes.count > 1 {
            notes.shuffle()
            if notes.map(\.id) == originalIDs {
                notes.append(notes.removeFirst())
            }
        }
        appendLog("乱序刷新")
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        eventLog.insert("\(formatter.string(from: Date()))  \(message)", at: 0)
        if eventLog.count > 80 {
            eventLog.removeLast(eventLog.count - 80)
        }
    }

    private static func makeNote(index: Int, kind: NoteReviewCardStackSampleNote.Kind) -> NoteReviewCardStackSampleNote {
        let palettes = [
            NoteReviewCardStackSamplePalette(backgroundHex: 0xA9C8DE, accentHex: 0x3B5568),
            NoteReviewCardStackSamplePalette(backgroundHex: 0xE7D8B8, accentHex: 0x735F3F),
            NoteReviewCardStackSamplePalette(backgroundHex: 0xC7D9BF, accentHex: 0x466044),
            NoteReviewCardStackSamplePalette(backgroundHex: 0xD7C6DF, accentHex: 0x60486B)
        ]
        let content: String
        let idea: String
        switch kind {
        case .text:
            content = "就像 C++ 的创造者本贾尼·斯特劳斯特鲁普曾说过的那样，如果把十年花在研究深奥的数学上，Unix 就会胎死腹中。"
            idea = "低阈值滑动适合轻量回顾，但卡内阅读必须优先保证稳定。"
        case .longText:
            content = Array(repeating: "阅读型卡片的第一职责不是被快速丢出去，而是让用户能安静看完。外层滑动要足够顺，但不能抢走内部滚动。", count: 10).joined(separator: "\n\n")
            idea = "这个场景用于验证 ScrollView 与外层卡堆手势仲裁。"
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
        return NoteReviewCardStackSampleNote(
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
