/**
 * [INPUT]: 依赖 DailyReadingRecord、NoteReviewCardItem、XMBookCover、Timeline 内容卡片/来源尾注、首页时间线共享配色令牌与统一记录动作回调
 * [OUTPUT]: 对外提供 DailyReadingRecordRow，渲染共享配色时间轴、无重复标题的四格打卡、固定类型相关书籍卡、内容记录卡与中性菜单操作
 * [POS]: ReadCalendar 当日阅读轨迹页面私有组件，统一主内容优先的信息层级、点击行为、长按菜单与辅助操作
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 当日记录菜单动作，页面负责执行导航、Repository 写入和系统能力。
enum DailyReadingRecordAction {
    case edit
    case editTags(NoteReviewCardItem)
    case copy(String)
    case openWeRead(URL)
    case shareNoteImage(NoteReviewCardItem)
    case sendNote(NoteReviewCardItem, ExternalAppDestination)
    case editRelatedBook
    case delete
}

/// 当日阅读轨迹记录行；书籍身份始终位于卡片内部，模糊计时不伪装具体钟点。
struct DailyReadingRecordRow: View {
    let record: DailyReadingRecord
    let isLast: Bool
    let noteActionItem: NoteReviewCardItem?
    let configuredExternalDestinations: Set<ExternalAppDestination>
    let onOpenContent: (ContentViewerItemID) -> Void
    let onOpenBook: (Int64) -> Void
    let onAction: (DailyReadingRecordAction) -> Void

    @ScaledMetric(relativeTo: .caption) private var connectorWidth = 44.0

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.none) {
            connector

            Button(action: handleTap) {
                cardContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recordAccessibilityLabel)
            .contextMenu {
                if hasRecordActions {
                    recordMenuItems
                }
            }
            .xmMenuNeutralTint()
            .accessibilityActions {
                if hasRecordActions {
                    recordAccessibilityActions
                }
            }
            .accessibilityHint(hasRecordActions ? "轻点打开，长按显示记录操作" : "轻点打开书籍")
            .padding(.leading, Spacing.cozy)
            .padding(.bottom, Spacing.screenEdge)
        }
    }

    private var connector: some View {
        VStack(spacing: Spacing.compact) {
            Text(timeText)
                .font(AppTypography.caption)
                .foregroundStyle(TimelineCalendarStyle.eventTimeColor)
                .monospacedDigit()
                .fixedSize()
                .accessibilityLabel(timelineTimeAccessibilityLabel)
            Circle()
                .fill(TimelineCalendarStyle.connectorDotColor)
                .frame(
                    width: TimelineCalendarStyle.connectorDotSize,
                    height: TimelineCalendarStyle.connectorDotSize
                )
            if !isLast {
                DailyReadingConnectorLine()
                    .stroke(
                        TimelineCalendarStyle.connectorLineColor,
                        style: StrokeStyle(
                            lineWidth: TimelineCalendarStyle.connectorLineWidth,
                            lineCap: .round,
                            dash: TimelineCalendarStyle.connectorDashPattern
                        )
                    )
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: connectorWidth)
    }

    @ViewBuilder
    private var cardContent: some View {
        switch record.event.kind {
        case .note(let event):
            TimelineNoteCard(
                event: event,
                timestamp: record.event.timestamp,
                bookName: record.event.bookName,
                presentationStyle: .contentFirst,
                actionColor: .textSecondary,
                quoteColor: UIColor.xmResolved(Color.textSecondary)
            )
        case .readTiming(let event):
            DailyReadingTimingCard(
                event: event,
                bookName: record.event.bookName,
                bookAuthor: record.event.bookAuthor,
                bookCover: record.event.bookCover
            )
        case .checkIn(let event):
            DailyReadingCheckInCard(
                event: event,
                bookName: record.event.bookName,
                bookAuthor: record.event.bookAuthor,
                bookCover: record.event.bookCover
            )
        case .review(let event):
            TimelineReviewCard(
                event: event,
                timestamp: record.event.timestamp,
                bookName: record.event.bookName,
                presentationStyle: .contentFirst,
                actionColor: .textSecondary
            )
        case .relevant(let event):
            TimelineRelevantCard(
                event: event,
                timestamp: record.event.timestamp,
                bookName: record.event.bookName,
                presentationStyle: .contentFirst,
                actionColor: .textSecondary
            )
        case .relevantBook(let event):
            DailyReadingRelatedBookCard(
                event: event,
                sourceBookName: record.event.bookName
            )
        case .readStatus(let event):
            DailyReadingReadDoneCard(
                event: event,
                bookName: record.event.bookName,
                bookAuthor: record.event.bookAuthor,
                bookCover: record.event.bookCover
            )
        }
    }

    @ViewBuilder
    private var recordMenuItems: some View {
        Button("打开书籍", systemImage: "book") {
            onOpenBook(record.event.sourceBookId)
        }

        switch record.event.kind {
        case .readTiming, .checkIn:
            Button("更新", systemImage: "pencil") { onAction(.edit) }
        case .note(let event):
            Button("编辑", systemImage: "pencil") { onAction(.edit) }

            if let noteActionItem {
                Button("编辑标签", systemImage: "tag") { onAction(.editTags(noteActionItem)) }
            }

            Menu("复制") {
                if TimelineMeaningfulText.hasMeaningfulHTML(event.content) {
                    Button("复制书摘") {
                        onAction(.copy(TimelineMeaningfulText.strippedHTML(event.content)))
                    }
                }
                if TimelineMeaningfulText.hasMeaningfulHTML(event.idea) {
                    Button("复制想法") {
                        onAction(.copy(TimelineMeaningfulText.strippedHTML(event.idea)))
                    }
                }
                if TimelineMeaningfulText.hasMeaningfulHTML(event.content),
                   TimelineMeaningfulText.hasMeaningfulHTML(event.idea) {
                    Button("复制全部") {
                        onAction(.copy([
                            TimelineMeaningfulText.strippedHTML(event.content),
                            TimelineMeaningfulText.strippedHTML(event.idea)
                        ].joined(separator: "\n\n")))
                    }
                }
            }

            if let item = noteActionItem {
                if let rawURL = item.weReadOriginalURL,
                   let url = URL(string: rawURL) {
                    Button("打开微信读书原文", systemImage: "book") {
                        onAction(.openWeRead(url))
                    }
                }
                Button("生成分享卡片", systemImage: "square.and.arrow.up") {
                    onAction(.shareNoteImage(item))
                }
                if !configuredExternalDestinations.isEmpty {
                    Menu("发送到") {
                        ForEach(ExternalAppDestination.allCases) { destination in
                            if configuredExternalDestinations.contains(destination) {
                                Button(destination.displayName, systemImage: destination.systemImageName) {
                                    onAction(.sendNote(item, destination))
                                }
                            }
                        }
                    }
                }
            }
        case .review, .relevant:
            Button("编辑", systemImage: "pencil") { onAction(.edit) }
            Button("复制", systemImage: "doc.on.doc") { onAction(.copy(shareText)) }
        case .relevantBook(let event):
            Button("打开相关书籍", systemImage: "books.vertical") {
                onOpenBook(event.contentBookId)
            }
            Button("编辑关联书籍", systemImage: "pencil") {
                onAction(.editRelatedBook)
            }
        case .readStatus:
            EmptyView()
        }

        if canDelete {
            Divider()
            Button(role: .destructive) {
                onAction(.delete)
            } label: {
                Label("删除", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    /// 将长按菜单中的命令扁平化为 VoiceOver 自定义操作，避免辅助功能用户依赖不可见手势。
    @ViewBuilder
    private var recordAccessibilityActions: some View {
        Button("打开书籍") {
            onOpenBook(record.event.sourceBookId)
        }

        switch record.event.kind {
        case .readTiming, .checkIn:
            Button("更新") { onAction(.edit) }
        case .note(let event):
            Button("编辑") { onAction(.edit) }

            if let noteActionItem {
                Button("编辑标签") { onAction(.editTags(noteActionItem)) }
            }

            if TimelineMeaningfulText.hasMeaningfulHTML(event.content) {
                Button("复制书摘") {
                    onAction(.copy(TimelineMeaningfulText.strippedHTML(event.content)))
                }
            }
            if TimelineMeaningfulText.hasMeaningfulHTML(event.idea) {
                Button("复制想法") {
                    onAction(.copy(TimelineMeaningfulText.strippedHTML(event.idea)))
                }
            }
            if TimelineMeaningfulText.hasMeaningfulHTML(event.content),
               TimelineMeaningfulText.hasMeaningfulHTML(event.idea) {
                Button("复制全部") {
                    onAction(.copy([
                        TimelineMeaningfulText.strippedHTML(event.content),
                        TimelineMeaningfulText.strippedHTML(event.idea)
                    ].joined(separator: "\n\n")))
                }
            }

            if let item = noteActionItem {
                if let rawURL = item.weReadOriginalURL,
                   let url = URL(string: rawURL) {
                    Button("打开微信读书原文") {
                        onAction(.openWeRead(url))
                    }
                }
                Button("生成分享卡片") {
                    onAction(.shareNoteImage(item))
                }
                ForEach(ExternalAppDestination.allCases) { destination in
                    if configuredExternalDestinations.contains(destination) {
                        Button("发送到\(destination.displayName)") {
                            onAction(.sendNote(item, destination))
                        }
                    }
                }
            }
        case .review, .relevant:
            Button("编辑") { onAction(.edit) }
            Button("复制") { onAction(.copy(shareText)) }
        case .relevantBook(let event):
            Button("打开相关书籍") {
                onOpenBook(event.contentBookId)
            }
            Button("编辑关联书籍") {
                onAction(.editRelatedBook)
            }
        case .readStatus:
            EmptyView()
        }

        if canDelete {
            Button("删除", role: .destructive) {
                onAction(.delete)
            }
        }
    }

    private var canDelete: Bool {
        guard record.recordID != nil else { return false }
        if case .readStatus = record.event.kind { return false }
        return true
    }

    private var hasRecordActions: Bool {
        if case .readStatus = record.event.kind { return false }
        return true
    }

    private var timeText: String {
        if case .readTiming(let event) = record.event.kind,
           event.fuzzyReadDate != 0 {
            return "补录"
        }
        return Self.timeFormatter.string(
            from: Date(timeIntervalSince1970: Double(record.event.timestamp) / 1_000)
        )
    }

    private var timelineTimeAccessibilityLabel: String {
        guard case .readTiming(let event) = record.event.kind,
              event.fuzzyReadDate != 0 else {
            return timeText
        }
        return DailyReadingTimingPresentation.accessibilityTimeDescription(for: event)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var recordAccessibilityLabel: String {
        let sourceDescription = "来源书籍《\(displaySourceBookName)》"

        switch record.event.kind {
        case .note(let event):
            return accessibilityDescription([
                TimelineMeaningfulText.strippedHTML(event.content),
                prefixedDescription("想法", html: event.idea),
                sourceDescription
            ])
        case .readTiming(let event):
            return accessibilityDescription([
                "阅读时长\(ReadDurationFormatter.format(seconds: event.elapsedSeconds))",
                timingDescription(for: event),
                prefixedDescription("阅读感想", html: event.insight),
                sourceDescription
            ])
        case .readStatus(let event):
            return accessibilityDescription([
                readingStatusDescription(for: event),
                ratingDescription(for: event.bookScore),
                sourceDescription
            ])
        case .checkIn(let event):
            let level = CheckInAmountLevel(amount: Int64(min(4, max(1, Int(event.amount)))))
            return "阅读打卡，阅读量\(level.label)，\(sourceDescription)"
        case .review(let event):
            return accessibilityDescription([
                TimelineMeaningfulText.trimmedText(event.title),
                TimelineMeaningfulText.strippedHTML(event.content),
                ratingDescription(for: event.bookScore),
                sourceDescription
            ])
        case .relevant(let event):
            return accessibilityDescription([
                TimelineMeaningfulText.trimmedText(event.title),
                TimelineMeaningfulText.strippedHTML(event.content),
                TimelineMeaningfulText.trimmedText(event.categoryTitle),
                sourceDescription
            ])
        case .relevantBook(let event):
            let relatedBookName = normalizedBookName(event.contentBookName)
            return accessibilityDescription([
                "相关书籍《\(relatedBookName)》",
                "类型，书籍",
                "关联自《\(displaySourceBookName)》"
            ])
        }
    }

    private var displaySourceBookName: String {
        normalizedBookName(record.event.bookName)
    }

    private func normalizedBookName(_ name: String) -> String {
        let trimmed = TimelineMeaningfulText.trimmedText(name)
        return trimmed.isEmpty ? "未命名书籍" : trimmed
    }

    private func accessibilityDescription(_ parts: [String?]) -> String {
        parts
            .compactMap { $0 }
            .map(TimelineMeaningfulText.trimmedText)
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }

    private func prefixedDescription(_ prefix: String, html: String) -> String? {
        guard TimelineMeaningfulText.hasMeaningfulHTML(html) else { return nil }
        return "\(prefix)，\(TimelineMeaningfulText.strippedHTML(html))"
    }

    private func timingDescription(for event: TimelineReadTimingEvent) -> String {
        DailyReadingTimingPresentation.accessibilityTimeDescription(for: event)
    }

    private func readingStatusDescription(for event: TimelineReadStatusEvent) -> String {
        event.readDoneCount > 1 ? "第 \(event.readDoneCount) 次读完" : "读完"
    }

    private func ratingDescription(for score: Int64) -> String? {
        guard score > 0 else { return nil }
        let rating = (Double(score) / 10).formatted(
            .number.precision(.fractionLength(1))
        )
        return "评分 \(rating) 星"
    }

    private var shareText: String {
        switch record.event.kind {
        case .note(let event):
            return [event.content, event.idea]
                .filter { TimelineMeaningfulText.hasMeaningfulHTML($0) }
                .map(TimelineMeaningfulText.strippedHTML)
                .joined(separator: "\n\n")
        case .review(let event):
            return [event.title, TimelineMeaningfulText.strippedHTML(event.content)]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        case .relevant(let event):
            return [event.title, TimelineMeaningfulText.strippedHTML(event.content), event.url]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        default:
            return record.event.bookName
        }
    }

    private func handleTap() {
        switch record.event.kind {
        case .note(let event): onOpenContent(.note(event.noteId))
        case .review(let event): onOpenContent(.review(event.reviewId))
        case .relevant(let event): onOpenContent(.relevant(event.contentId))
        case .relevantBook(let event): onOpenBook(event.contentBookId)
        case .readTiming, .checkIn: onAction(.edit)
        case .readStatus: onOpenBook(record.event.sourceBookId)
        }
    }
}

/// 当日阅读时长卡；突出读数，并把时间范围和阅读感想降为辅助层级。
private struct DailyReadingTimingCard: View {
    let event: TimelineReadTimingEvent
    let bookName: String
    let bookAuthor: String
    let bookCover: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        CardContainer(
            cornerRadius: TimelineCalendarStyle.eventCardCornerRadius,
            showsBorder: true,
            borderColor: .surfaceBorderSubtle
        ) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                DailyReadingTimingHero(
                    event: event,
                    bookName: bookName,
                    bookAuthor: bookAuthor,
                    bookCover: bookCover,
                    layout: dynamicTypeSize.isAccessibilitySize ? .stacked : .inline
                )

                if hasInsight {
                    TimelineCardDivider()

                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text("阅读感想")
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(Color.textSecondary)

                        ExpandableRichText(
                            html: event.insight,
                            baseFont: NoteExcerptTypography.uiIdea,
                            textColor: UIColor.xmResolved(Color.textSecondary),
                            lineSpacing: NoteExcerptTypography.ideaLineSpacing,
                            actionColor: .textSecondary
                        )
                        .equatable()
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .contain)
    }

    private var hasInsight: Bool {
        TimelineMeaningfulText.hasMeaningfulHTML(event.insight)
    }
}

/// 阅读时长卡的封面、书籍信息与时长主值；辅助功能字号下改为上下结构保护主时长。
private struct DailyReadingTimingHero: View {
    enum Layout {
        case inline
        case stacked
    }

    let event: TimelineReadTimingEvent
    let bookName: String
    let bookAuthor: String
    let bookCover: String
    let layout: Layout

    @ScaledMetric(relativeTo: .body) private var coverWidth = 48.0

    @ViewBuilder
    var body: some View {
        switch layout {
        case .inline:
            HStack(alignment: .center, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    cover
                    bookText
                        .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
                }

                durationCapsule
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .accessibilityElement(children: .combine)
        case .stacked:
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    cover
                    bookText
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                durationCapsule
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private var cover: some View {
        XMBookCover.fixedWidth(
            min(coverWidth, 64),
            urlString: bookCover,
            border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth),
            placeholderIconSize: .small
        )
        .accessibilityHidden(true)
    }

    private var bookText: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(displayBookName)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !displayBookAuthor.isEmpty {
                    Text(displayBookAuthor)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Text(DailyReadingTimingPresentation.timeDescription(for: event))
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textHint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var durationCapsule: some View {
        DailyReadingDurationValue(seconds: event.elapsedSeconds)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.compact)
            .background(
                Color.surfaceNested,
                in: Capsule()
            )
    }

    private var displayBookName: String {
        let trimmed = TimelineMeaningfulText.trimmedText(bookName)
        return trimmed.isEmpty ? "未命名书籍" : trimmed
    }

    private var displayBookAuthor: String {
        TimelineMeaningfulText.trimmedText(bookAuthor)
    }
}

/// 阅读时长的数字与单位排版；数字承担首要视觉，单位保持同组但退后一层。
private struct DailyReadingDurationValue: View {
    let seconds: Int64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.none) {
            if hours > 0 {
                valuePair(number: hours, unit: "小时")
                if minutes > 0 {
                    valuePair(number: minutes, unit: "分钟")
                }
            } else if minutes > 0 {
                valuePair(number: minutes, unit: "分钟")
                if remainingSeconds > 0 {
                    valuePair(number: remainingSeconds, unit: "秒")
                }
            } else {
                valuePair(number: remainingSeconds, unit: "秒")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ReadDurationFormatter.format(seconds: seconds))
    }

    private var clampedSeconds: Int64 { max(0, seconds) }
    private var hours: Int64 { clampedSeconds / 3_600 }
    private var minutes: Int64 { (clampedSeconds % 3_600) / 60 }
    private var remainingSeconds: Int64 { clampedSeconds % 60 }

    /// 生成一组同基线的数值与单位，避免把完整时长压成单一胶囊文案。
    private func valuePair(number: Int64, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.tiny) {
            Text(number, format: .number)
                .font(AppTypography.brandDisplay(size: 18, relativeTo: .body))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
            Text(unit)
                .font(AppTypography.caption2Medium)
                .foregroundStyle(Color.textSecondary)
        }
    }
}

/// 统一生成精确计时范围与模糊记录补记日期的视觉、辅助功能文案。
private enum DailyReadingTimingPresentation {
    static func timeDescription(for event: TimelineReadTimingEvent) -> String {
        guard event.fuzzyReadDate != 0 else {
            return exactTimeDescription(for: event, separator: "–")
        }
        guard let supplementedAt = event.supplementedAt else {
            return "补记时间未知"
        }

        let supplementedDate = date(from: supplementedAt)
        let readingDate = date(from: event.fuzzyReadDate)
        if calendar.component(.year, from: supplementedDate)
            == calendar.component(.year, from: readingDate) {
            return "\(monthDayFormatter.string(from: supplementedDate))补记"
        }
        return "\(fullDateFormatter.string(from: supplementedDate))补记"
    }

    static func accessibilityTimeDescription(for event: TimelineReadTimingEvent) -> String {
        guard event.fuzzyReadDate == 0 else {
            return timeDescription(for: event)
        }
        return exactTimeDescription(for: event, separator: "至")
    }

    private static func exactTimeDescription(
        for event: TimelineReadTimingEvent,
        separator: String
    ) -> String {
        guard event.startTime > 0, event.endTime > 0 else {
            return "未记录具体时间"
        }
        return "\(timeFormatter.string(from: date(from: event.startTime)))\(separator)\(timeFormatter.string(from: date(from: event.endTime)))"
    }

    private static func date(from milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static let calendar = Calendar.current

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}

/// 当日阅读打卡卡；以书籍身份为主体，并用热力图色标记四级阅读量中的当前档位。
private struct DailyReadingCheckInCard: View {
    let event: TimelineCheckInEvent
    let bookName: String
    let bookAuthor: String
    let bookCover: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        CardContainer(
            cornerRadius: TimelineCalendarStyle.eventCardCornerRadius,
            showsBorder: true,
            borderColor: .surfaceBorderSubtle
        ) {
            DailyReadingCheckInHero(
                bookName: bookName,
                bookAuthor: bookAuthor,
                bookCover: bookCover,
                level: level,
                selectedLevel: selectedLevel,
                layout: dynamicTypeSize.isAccessibilitySize ? .stacked : .inline
            )
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("阅读打卡，阅读量\(level.label)，来源书籍《\(displayBookName)》")
    }

    private var selectedLevel: Int {
        min(4, max(1, Int(event.amount)))
    }

    private var level: CheckInAmountLevel {
        CheckInAmountLevel(amount: Int64(selectedLevel))
    }

    private var displayBookName: String {
        let trimmed = TimelineMeaningfulText.trimmedText(bookName)
        return trimmed.isEmpty ? "未命名书籍" : trimmed
    }
}

/// 打卡卡的书籍信息与阅读量热力格；辅助功能字号下分行，避免等级图例挤压书名。
private struct DailyReadingCheckInHero: View {
    enum Layout {
        case inline
        case stacked
    }

    let bookName: String
    let bookAuthor: String
    let bookCover: String
    let level: CheckInAmountLevel
    let selectedLevel: Int
    let layout: Layout

    @ScaledMetric(relativeTo: .body) private var coverWidth = 48.0

    @ViewBuilder
    var body: some View {
        switch layout {
        case .inline:
            HStack(alignment: .center, spacing: Spacing.base) {
                bookIdentity
                    .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)

                levelIndicator
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        case .stacked:
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                bookIdentity
                    .frame(maxWidth: .infinity, alignment: .leading)

                levelIndicator
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bookIdentity: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                min(coverWidth, 64),
                urlString: bookCover,
                border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth),
                placeholderIconSize: .small
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(displayBookName)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)

                if !displayBookAuthor.isEmpty {
                    Text(displayBookAuthor)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var levelIndicator: some View {
        ReadingCheckInLevelIndicator(
            selectedLevel: selectedLevel,
            label: level.label
        )
        .accessibilityHidden(true)
    }

    private var displayBookName: String {
        let trimmed = TimelineMeaningfulText.trimmedText(bookName)
        return trimmed.isEmpty ? "未命名书籍" : trimmed
    }

    private var displayBookAuthor: String {
        TimelineMeaningfulText.trimmedText(bookAuthor)
    }
}

/// 当日读完里程碑卡；以封面和作者建立书籍身份，状态与评分作为右侧结果信息。
private struct DailyReadingReadDoneCard: View {
    let event: TimelineReadStatusEvent
    let bookName: String
    let bookAuthor: String
    let bookCover: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        CardContainer(
            cornerRadius: TimelineCalendarStyle.eventCardCornerRadius,
            showsBorder: true,
            borderColor: .surfaceBorderSubtle
        ) {
            DailyReadingReadDoneHero(
                event: event,
                bookName: bookName,
                bookAuthor: bookAuthor,
                bookCover: bookCover,
                layout: dynamicTypeSize.isAccessibilitySize ? .stacked : .inline
            )
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 读完卡的书籍信息、状态与评分布局；辅助功能字号下分行以避免尾部信息挤压书名。
private struct DailyReadingReadDoneHero: View {
    enum Layout {
        case inline
        case stacked
    }

    let event: TimelineReadStatusEvent
    let bookName: String
    let bookAuthor: String
    let bookCover: String
    let layout: Layout

    @ScaledMetric(relativeTo: .body) private var coverWidth = 48.0

    @ViewBuilder
    var body: some View {
        switch layout {
        case .inline:
            HStack(alignment: .center, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    cover
                    bookText
                        .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
                }

                resultContent
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .accessibilityElement(children: .combine)
        case .stacked:
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    cover
                    bookText
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                stackedResultContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private var cover: some View {
        XMBookCover.fixedWidth(
            min(coverWidth, 64),
            urlString: bookCover,
            border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth),
            placeholderIconSize: .small
        )
        .accessibilityHidden(true)
    }

    private var bookText: some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            Text(displayBookName)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if !displayBookAuthor.isEmpty {
                Text(displayBookAuthor)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var resultContent: some View {
        VStack(alignment: .trailing, spacing: Spacing.cozy) {
            statusBadge

            if showsRating {
                rating
            }
        }
    }

    private var stackedResultContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.base) {
                statusBadge

                Spacer(minLength: Spacing.base)

                if showsRating {
                    rating
                }
            }

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                statusBadge

                if showsRating {
                    rating
                }
            }
        }
    }

    private var statusBadge: some View {
        Text(readDoneTitle)
            .font(AppTypography.caption2Medium)
            .foregroundStyle(.white)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(Color.statusDone, in: Capsule())
    }

    private var rating: some View {
        XMRatingBar(score: event.bookScore, preset: .listSmall)
    }

    private var readDoneTitle: String {
        event.readDoneCount > 1 ? "第 \(event.readDoneCount) 次读完" : "读完"
    }

    private var showsRating: Bool {
        event.bookScore > 0
    }

    private var displayBookName: String {
        let trimmed = TimelineMeaningfulText.trimmedText(bookName)
        return trimmed.isEmpty ? "未命名书籍" : trimmed
    }

    private var displayBookAuthor: String {
        TimelineMeaningfulText.trimmedText(bookAuthor)
    }
}

/// 当日相关书籍卡；关联目标书作为主内容，并以普通辅助文字明确固定类型与来源关系。
private struct DailyReadingRelatedBookCard: View {
    let event: TimelineRelevantBookEvent
    let sourceBookName: String

    var body: some View {
        CardContainer(
            cornerRadius: TimelineCalendarStyle.eventCardCornerRadius,
            showsBorder: true,
            borderColor: .surfaceBorderSubtle
        ) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    XMBookCover.fixedWidth(
                        48,
                        urlString: event.contentBookCover,
                        border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth),
                        placeholderIconSize: .small
                    )
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Spacing.tiny) {
                        Text(displayBookName)
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .truncationMode(.tail)

                        if !displayBookAuthor.isEmpty {
                            Text(displayBookAuthor)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer(minLength: 0)
                }

                TimelineRelatedBookMetadata(sourceBookName: sourceBookName)
            }
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .combine)
    }

    private var displayBookName: String {
        let trimmed = TimelineMeaningfulText.trimmedText(event.contentBookName)
        return trimmed.isEmpty ? "未命名书籍" : trimmed
    }

    private var displayBookAuthor: String {
        TimelineMeaningfulText.trimmedText(event.contentBookAuthor)
    }
}

/// 轨迹节点后的垂直连接线；由记录行决定是否绘制末段，保持路径计算无状态且可复用布局高度。
private struct DailyReadingConnectorLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
