#if DEBUG
/**
 * [INPUT]: 依赖 TimelineEventRow/TimelineSectionView/TimelineSectionHeader、7 种 Card 组件、TimelineModels 领域模型
 * [OUTPUT]: 对外提供 TimelineCardsTestView（时间线卡片测试页面）
 * [POS]: Debug 测试页，可视化验证 7 种事件卡片样式与时间线装饰器
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

// MARK: - 外壳

struct TimelineCardsTestView: View {
    @State private var selectedCategory: TimelineEventCategory = .all

    var body: some View {
        TimelineCardsTestContentView(selectedCategory: $selectedCategory)
    }
}

// MARK: - 内容子视图

private struct TimelineCardsTestContentView: View {
    @Binding var selectedCategory: TimelineEventCategory

    private var filteredSections: [TimelineSection] {
        guard selectedCategory != .all else {
            return TimelineCardsMockData.sections
        }
        return TimelineCardsMockData.sections.compactMap { section in
            let filtered = section.events.filter { event in
                switch (selectedCategory, event.kind) {
                case (.note, .note): true
                case (.readTiming, .readTiming): true
                case (.readStatus, .readStatus): true
                case (.checkIn, .checkIn): true
                case (.review, .review): true
                case (.relevant, .relevant), (.relevant, .relevantBook): true
                default: false
                }
            }
            guard !filtered.isEmpty else { return nil }
            return TimelineSection(id: section.id, date: section.date, events: filtered)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                categoryPicker
                timelineList
            }
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .clipped()
        .background(Color.windowBackground)
        .navigationTitle("时间线卡片")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Category Picker

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.half) {
                ForEach(TimelineEventCategory.allCases) { category in
                    Button(category.rawValue) {
                        withAnimation(.snappy) {
                            selectedCategory = category
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        selectedCategory == category
                            ? Color.brand : Color.bgSecondary
                    )
                    .foregroundStyle(
                        selectedCategory == category
                            ? .white : Color.textPrimary
                    )
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
        }
    }

    // MARK: - Timeline List

    private var timelineList: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(Array(filteredSections.enumerated()), id: \.element.id) { index, section in
                TimelineSectionView(
                    section: section,
                    isFirst: index == 0,
                    isLast: index == filteredSections.count - 1,
                    selectedCategory: .all,
                    onCategorySelected: { _ in }
                )
            }
        }
    }
}

// MARK: - Mock Data

enum TimelineCardsMockData {

    static let sections: [TimelineSection] = [
        todaySection,
        yesterdaySection,
        threeDaysAgoSection,
    ]

    // MARK: - Today

    private static var todaySection: TimelineSection {
        let today = Calendar.current.startOfDay(for: Date())
        let base = Int64(today.timeIntervalSince1970 * 1000)
        return TimelineSection(
            id: dateId(today),
            date: today,
            events: [
                TimelineEvent(
                    id: "note_1",
                    kind: .note(TimelineNoteEvent(
                        content: "人生最大的幸运，就是在年富力强时发现了自己的使命。一个人知道自己为什么活着，就能忍受任何一种生活。",
                        idea: "这句话让我想到了尼采的名言——知道为什么活的人，便能生存",
                        bookTitle: "活法"
                    )),
                    timestamp: base + 36000000,
                    bookName: "活法",
                    bookAuthor: "稻盛和夫",
                    bookCover: ""
                ),
                TimelineEvent(
                    id: "timing_1",
                    kind: .readTiming(TimelineReadTimingEvent(
                        elapsedSeconds: 6300,
                        startTime: base + 28800000,
                        endTime: base + 35100000,
                        fuzzyReadDate: 0
                    )),
                    timestamp: base + 28800000,
                    bookName: "人类简史",
                    bookAuthor: "尤瓦尔·赫拉利",
                    bookCover: ""
                ),
                TimelineEvent(
                    id: "status_1",
                    kind: .readStatus(TimelineReadStatusEvent(
                        statusId: 3,
                        readDoneCount: 2,
                        bookScore: 45
                    )),
                    timestamp: base + 25200000,
                    bookName: "百年孤独",
                    bookAuthor: "加西亚·马尔克斯",
                    bookCover: ""
                ),
            ]
        )
    }

    // MARK: - Yesterday

    private static var yesterdaySection: TimelineSection {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let base = Int64(yesterday.timeIntervalSince1970 * 1000)
        return TimelineSection(
            id: dateId(yesterday),
            date: yesterday,
            events: [
                TimelineEvent(
                    id: "checkin_1",
                    kind: .checkIn(TimelineCheckInEvent(amount: 3)),
                    timestamp: base + 72000000,
                    bookName: "原则",
                    bookAuthor: "瑞·达利欧",
                    bookCover: ""
                ),
                TimelineEvent(
                    id: "review_1",
                    kind: .review(TimelineReviewEvent(
                        title: "一本改变思维方式的书",
                        content: "作者用大量案例说明了系统思维的重要性。读完之后对复杂问题的分析能力有了显著提升，强烈推荐给所有想要提升认知能力的人。",
                        bookScore: 40
                    )),
                    timestamp: base + 64800000,
                    bookName: "系统之美",
                    bookAuthor: "德内拉·梅多斯",
                    bookCover: ""
                ),
                TimelineEvent(
                    id: "note_2",
                    kind: .note(TimelineNoteEvent(
                        content: "简洁是最高形式的复杂。",
                        idea: "",
                        bookTitle: "设计心理学"
                    )),
                    timestamp: base + 57600000,
                    bookName: "设计心理学",
                    bookAuthor: "唐纳德·诺曼",
                    bookCover: ""
                ),
            ]
        )
    }

    // MARK: - Three Days Ago

    private static var threeDaysAgoSection: TimelineSection {
        let date = Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: Date()))!
        let base = Int64(date.timeIntervalSince1970 * 1000)
        return TimelineSection(
            id: dateId(date),
            date: date,
            events: [
                TimelineEvent(
                    id: "relevant_1",
                    kind: .relevant(TimelineRelevantEvent(
                        title: "作者的 TED 演讲",
                        content: "关于创造力与约束之间关系的精彩演讲，与书中第三章的论述高度呼应。",
                        url: "https://example.com/ted-talk",
                        categoryTitle: "延伸阅读"
                    )),
                    timestamp: base + 50400000,
                    bookName: "创新者的窘境",
                    bookAuthor: "克里斯坦森",
                    bookCover: ""
                ),
                TimelineEvent(
                    id: "relevantbook_1",
                    kind: .relevantBook(TimelineRelevantBookEvent(
                        contentBookName: "思考快与慢",
                        contentBookAuthor: "丹尼尔·卡尼曼",
                        contentBookCover: "",
                        categoryTitle: "书"
                    )),
                    timestamp: base + 43200000,
                    bookName: "创新者的窘境",
                    bookAuthor: "克里斯坦森",
                    bookCover: ""
                ),
                TimelineEvent(
                    id: "status_2",
                    kind: .readStatus(TimelineReadStatusEvent(
                        statusId: 1,
                        readDoneCount: 0,
                        bookScore: 0
                    )),
                    timestamp: base + 36000000,
                    bookName: "深度工作",
                    bookAuthor: "卡尔·纽波特",
                    bookCover: ""
                ),
                TimelineEvent(
                    id: "checkin_2",
                    kind: .checkIn(TimelineCheckInEvent(amount: 1)),
                    timestamp: base + 28800000,
                    bookName: "刻意练习",
                    bookAuthor: "安德斯·艾利克森",
                    bookCover: ""
                ),
            ]
        )
    }

    // MARK: - Helpers

    private static func dateId(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

#Preview {
    NavigationStack {
        TimelineCardsTestView()
    }
}
#endif
