/**
 * [INPUT]: 依赖 TimelineViewModel 与可脚本化 TimelineRepositoryProtocol 测试替身
 * [OUTPUT]: 验证首次失败可重试，以及刷新失败时保留可信时间线内容
 * [POS]: xmnoteTests 的时间线状态回归测试，保护 failure、empty 与 refresh error 的边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Testing
@testable import xmnote

@MainActor
struct TimelineStateTests {
    @Test
    func initialFailureCanRetryIntoReadyContent() async {
        let expected = [Self.section(id: "retry")]
        let repository = ScriptedTimelineRepository(eventSteps: [.failure, .success(expected)])
        let viewModel = TimelineViewModel(repository: repository)

        await viewModel.loadInitialData()
        #expect(viewModel.bootstrapPhase == .failed)
        #expect(viewModel.sections.isEmpty)
        #expect(viewModel.initialErrorMessage != nil)

        await viewModel.retryInitialData()
        #expect(viewModel.bootstrapPhase == .ready)
        #expect(viewModel.sections == expected)
        #expect(viewModel.initialErrorMessage == nil)
    }

    @Test
    func refreshFailureKeepsPreviouslyLoadedSections() async {
        let expected = [Self.section(id: "existing")]
        let repository = ScriptedTimelineRepository(eventSteps: [.success(expected), .failure])
        let viewModel = TimelineViewModel(repository: repository)

        await viewModel.loadInitialData()
        let didRefresh = await viewModel.loadEvents()

        #expect(!didRefresh)
        #expect(viewModel.bootstrapPhase == .ready)
        #expect(viewModel.sections == expected)
        #expect(viewModel.refreshErrorMessage == "时间线更新失败，请重试")
    }

    private static func section(id: String) -> TimelineSection {
        TimelineSection(
            id: id,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            events: [
                TimelineEvent(
                    id: "event-\(id)",
                    kind: .checkIn(TimelineCheckInEvent(amount: 1)),
                    timestamp: 1_700_000_000_000,
                    sourceBookId: 1,
                    bookName: "测试书籍",
                    bookAuthor: "作者",
                    bookCover: ""
                )
            ]
        )
    }
}

private final class ScriptedTimelineRepository: TimelineRepositoryProtocol, @unchecked Sendable {
    enum EventStep {
        case success([TimelineSection])
        case failure
    }

    private var eventSteps: [EventStep]

    init(eventSteps: [EventStep]) {
        self.eventSteps = eventSteps
    }

    func fetchTimelineEvents(
        startTimestamp: Int64,
        endTimestamp: Int64,
        category: TimelineEventCategory
    ) async throws -> [TimelineSection] {
        let step = eventSteps.isEmpty ? .success([]) : eventSteps.removeFirst()
        switch step {
        case .success(let sections):
            return sections
        case .failure:
            throw StubTimelineError.failed
        }
    }

    func fetchCalendarMarkers(
        for monthStart: Date,
        category: TimelineEventCategory
    ) async throws -> [Date: TimelineDayMarker] {
        [:]
    }
}

private enum StubTimelineError: Error {
    case failed
}
