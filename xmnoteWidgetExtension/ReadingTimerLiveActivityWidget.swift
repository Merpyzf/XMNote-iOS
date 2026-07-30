import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import UIKit
import WidgetKit

/**
 * [INPUT]: 依赖 WidgetKit/ActivityKit 渲染 ReadingTimerActivityAttributes，依赖 xmnote://reading-timer 深链回到 App 计时页
 * [OUTPUT]: 对外提供 ReadingTimerLiveActivityWidget 与 WidgetBundle，展示锁屏与灵动岛阅读计时状态并保持展开态读数锚点稳定
 * [POS]: Widget Extension 的阅读计时 Live Activity UI，作为 App 内计时流程的系统状态补充
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@main
/// Widget 扩展入口，当前仅承载阅读计时 Live Activity。
struct XMNoteWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        ReadingTimerLiveActivityWidget()
    }
}

/// 阅读计时 Live Activity Widget，覆盖锁屏、灵动岛紧凑态、展开态和最小态。
struct ReadingTimerLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReadingTimerActivityAttributes.self) { context in
            ReadingTimerLockScreenView(context: context)
                .activityBackgroundTint(Color(.secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(deepLinkURL(for: context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ReadingTimerIslandCover(
                        snapshotName: context.state.bookCoverSnapshotName,
                        remoteURLString: context.attributes.bookCoverURL,
                        bookName: context.attributes.bookName,
                        variant: .expanded
                    )
                    .padding(.top, ReadingTimerIslandExpandedMetrics.coverTop)
                }
                DynamicIslandExpandedRegion(.center) {
                    ReadingTimerIslandExpandedTextStack(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ReadingTimerIslandControlCluster(context: context)
                        .padding(.top, ReadingTimerIslandExpandedMetrics.nativeRegionControlsTop)
                }
            } compactLeading: {
                ReadingTimerIslandCover(
                    snapshotName: context.state.bookCoverSnapshotName,
                    remoteURLString: context.attributes.bookCoverURL,
                    bookName: context.attributes.bookName,
                    variant: .compact
                )
            } compactTrailing: {
                ReadingTimerIslandElapsedText(state: context.state, variant: .compact)
            } minimal: {
                ReadingTimerIslandCover(
                    snapshotName: context.state.bookCoverSnapshotName,
                    remoteURLString: context.attributes.bookCoverURL,
                    bookName: context.attributes.bookName,
                    variant: .minimal
                )
            }
            .widgetURL(deepLinkURL(for: context))
            .contentMargins(.leading, 7, for: .compactLeading)
            .contentMargins(.all, 3, for: .minimal)
            .contentMargins(.leading, ReadingTimerIslandExpandedMetrics.contentLeadingMargin, for: .expanded)
            .contentMargins(.trailing, ReadingTimerIslandExpandedMetrics.contentTrailingMargin, for: .expanded)
            .contentMargins(.vertical, ReadingTimerIslandExpandedMetrics.contentVerticalMargin, for: .expanded)
        }
    }

    private func deepLinkURL(for context: ActivityViewContext<ReadingTimerActivityAttributes>) -> URL? {
        var components = URLComponents()
        components.scheme = "xmnote"
        components.host = "reading-timer"
        components.path = "/\(context.attributes.bookId)"
        components.queryItems = [
            URLQueryItem(name: "recordId", value: "\(context.attributes.recordId)")
        ]
        return components.url
    }

}

private struct ReadingTimerIslandExpandedTextStack: View {
    let context: ActivityViewContext<ReadingTimerActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: ReadingTimerIslandExpandedMetrics.titleAuthorSpacing) {
            Text(context.attributes.bookName)
                .font(ReadingTimerIslandExpandedMetrics.titleFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .truncationMode(.tail)

            Text(detailText)
                .font(ReadingTimerIslandExpandedMetrics.authorFont)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)

            Color.clear
                .frame(height: ReadingTimerIslandExpandedMetrics.authorTimerSpacing)

            ReadingTimerIslandElapsedText(state: context.state, variant: .expanded)

            Spacer(minLength: 0)
        }
        .frame(
            width: ReadingTimerIslandExpandedMetrics.textColumnWidth,
            height: ReadingTimerIslandExpandedMetrics.nativeRegionTextHeight,
            alignment: .topLeading
        )
        .padding(.leading, ReadingTimerIslandExpandedMetrics.nativeRegionTextLeading)
        .padding(.top, ReadingTimerIslandExpandedMetrics.nativeRegionTextTop)
    }

    private var detailText: String {
        let author = context.attributes.author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !author.isEmpty { return author }
        if context.state.isPendingSave { return "待保存" }
        if context.state.isPaused { return "已暂停" }
        return "阅读中"
    }
}

private struct ReadingTimerLockScreenView: View {
    let context: ActivityViewContext<ReadingTimerActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ReadingTimerIslandCover(
                snapshotName: context.state.bookCoverSnapshotName,
                remoteURLString: context.attributes.bookCoverURL,
                bookName: context.attributes.bookName,
                variant: .lockScreen
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.bookName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ReadingTimerIslandElapsedText(state: context.state, variant: .lockScreen)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusText: String {
        if context.state.isPendingSave { return "待保存" }
        return context.state.isPaused ? "已暂停" : "阅读中"
    }
}

private struct ReadingTimerIslandControlCluster: View {
    let context: ActivityViewContext<ReadingTimerActivityAttributes>

    var body: some View {
        let model = ReadingTimerIslandControlModel(
            recordId: context.attributes.recordId,
            state: context.state
        )

        HStack(spacing: ReadingTimerIslandExpandedMetrics.controlButtonSpacing) {
            ReadingTimerIslandControlButton(
                recordId: model.recordId,
                action: model.primaryAction,
                systemImage: model.primarySystemImage,
                accessibilityLabel: model.primaryAccessibilityLabel,
                isEnabled: model.primaryAction != nil,
                animationKey: model.primaryAnimationKey
            )

            ReadingTimerIslandControlButton(
                recordId: model.recordId,
                action: model.stopAction,
                systemImage: model.stopSystemImage,
                accessibilityLabel: model.stopAccessibilityLabel,
                isEnabled: model.stopAction != nil,
                animationKey: model.stopAnimationKey
            )
        }
    }
}

private struct ReadingTimerIslandControlModel {
    let recordId: Int64
    let primaryAction: ReadingTimerLiveActivityControlAction?
    let primarySystemImage: String
    let primaryAccessibilityLabel: String
    let stopAction: ReadingTimerLiveActivityControlAction?
    let stopSystemImage: String
    let stopAccessibilityLabel: String
    let controlRevision: Int64

    init(recordId: Int64, state: ReadingTimerActivityAttributes.ContentState) {
        self.recordId = recordId
        controlRevision = state.effectiveControlRevision

        if state.isRunning {
            primaryAction = .pause
            primarySystemImage = "pause.fill"
            primaryAccessibilityLabel = "暂停阅读计时"
            stopAction = .stop
            stopSystemImage = "stop.fill"
            stopAccessibilityLabel = "结束阅读计时"
        } else if state.isPaused {
            primaryAction = .resume
            primarySystemImage = "play.fill"
            primaryAccessibilityLabel = "继续阅读计时"
            stopAction = .stop
            stopSystemImage = "stop.fill"
            stopAccessibilityLabel = "结束阅读计时"
        } else if state.isPendingSave {
            primaryAction = nil
            primarySystemImage = "ellipsis"
            primaryAccessibilityLabel = "阅读计时待保存"
            stopAction = nil
            stopSystemImage = "stop.fill"
            stopAccessibilityLabel = "计时已结束"
        } else {
            primaryAction = nil
            primarySystemImage = "pause.fill"
            primaryAccessibilityLabel = "计时已停止"
            stopAction = nil
            stopSystemImage = "stop.fill"
            stopAccessibilityLabel = "计时已停止"
        }
    }

    var primaryAnimationKey: String {
        "\(controlRevision)-primary-\(primarySystemImage)"
    }

    var stopAnimationKey: String {
        "\(controlRevision)-stop-\(stopSystemImage)"
    }
}

private struct ReadingTimerIslandControlButton: View {
    let recordId: Int64
    let action: ReadingTimerLiveActivityControlAction?
    let systemImage: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let animationKey: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        switch action {
        case .pause:
            Button(intent: ReadingTimerPauseLiveActivityIntent(recordId: recordId)) {
                icon
            }
            .buttonStyle(ReadingTimerIslandControlButtonStyle(isEnabled: isEnabled))
        case .resume:
            Button(intent: ReadingTimerResumeLiveActivityIntent(recordId: recordId)) {
                icon
            }
            .buttonStyle(ReadingTimerIslandControlButtonStyle(isEnabled: isEnabled))
        case .stop:
            Button(intent: ReadingTimerStopLiveActivityIntent(recordId: recordId)) {
                icon
            }
            .buttonStyle(ReadingTimerIslandControlButtonStyle(isEnabled: isEnabled))
        case nil:
            icon
                .modifier(ReadingTimerIslandControlButtonChrome(isEnabled: isEnabled, isPressed: false))
        }
    }

    private var icon: some View {
        iconImage
            .frame(
                width: ReadingTimerIslandExpandedMetrics.controlIconFrame.width,
                height: ReadingTimerIslandExpandedMetrics.controlIconFrame.height
            )
            .frame(
                width: ReadingTimerIslandExpandedMetrics.controlButtonSize,
                height: ReadingTimerIslandExpandedMetrics.controlButtonSize
            )
            .contentShape(Circle())
            .accessibilityLabel(accessibilityLabel)
            .animation(.snappy(duration: 0.18), value: animationKey)
            .animation(.snappy(duration: 0.16), value: isEnabled)
    }

    @ViewBuilder
    private var iconImage: some View {
        let image = Image(systemName: systemImage)
            .font(ReadingTimerIslandExpandedMetrics.controlIconFont(for: systemImage))
            .foregroundStyle(.white.opacity(isEnabled ? 0.96 : 0.42))

        if reduceMotion {
            image
                .contentTransition(.opacity)
        } else {
            image
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce.down, options: .speed(1.8), value: animationKey)
        }
    }
}

private struct ReadingTimerIslandControlButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(
                ReadingTimerIslandControlButtonChrome(
                    isEnabled: isEnabled,
                    isPressed: configuration.isPressed
                )
            )
    }
}

private struct ReadingTimerIslandControlButtonChrome: ViewModifier {
    let isEnabled: Bool
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .background {
                Circle()
                    .fill(Color.white.opacity(backgroundOpacity))
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1)
                    }
            }
            .scaleEffect(isPressed ? 0.88 : 1)
            .opacity(isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.12), value: isPressed)
            .animation(.snappy(duration: 0.16), value: isEnabled)
            .frame(
                width: ReadingTimerIslandExpandedMetrics.controlButtonSize,
                height: ReadingTimerIslandExpandedMetrics.controlButtonSize
            )
    }

    private var backgroundOpacity: Double {
        if isPressed { return 0.30 }
        return isEnabled ? 0.20 : 0.12
    }

    private var strokeOpacity: Double {
        if isPressed { return 0.28 }
        return isEnabled ? 0.18 : 0.08
    }
}

private enum ReadingTimerIslandExpandedMetrics {
    static let contentLeadingMargin: CGFloat = 34
    static let contentTrailingMargin: CGFloat = 19
    static let contentVerticalMargin: CGFloat = 0

    static let coverFrameSize = CGSize(width: 80, height: 120)
    static let coverArtSize = CGSize(width: 69, height: 107)
    static let coverTop: CGFloat = 22
    static let coverFrameCornerRadius: CGFloat = 5
    static let coverArtCornerRadius: CGFloat = 4
    static let coverFrameFill = Color(white: 0.58)

    static let textColumnWidth: CGFloat = 163
    static let titleAuthorSpacing: CGFloat = 0
    static let elapsedWidth: CGFloat = 88

    static let nativeRegionTextLeading: CGFloat = 21
    static let nativeRegionTextTop: CGFloat = -3
    static let nativeRegionTextHeight: CGFloat = 125
    static let authorTimerSpacing: CGFloat = 17
    static let nativeRegionControlsTop: CGFloat = 79
    static let controlButtonSize: CGFloat = 55
    static let controlButtonSpacing: CGFloat = 17
    static let controlIconFrame = CGSize(width: 28, height: 28)

    static let titleFont = Font.title3.weight(.semibold)
    static let authorFont = Font.headline.weight(.regular)
    static let timerFont = Font.title.weight(.regular)

    static func controlIconFont(for systemImage: String) -> Font {
        if systemImage == "stop.fill" {
            return .title3.weight(.semibold)
        }
        return .title2.weight(.semibold)
    }
}

private struct ReadingTimerIslandElapsedText: View {
    let state: ReadingTimerActivityAttributes.ContentState
    let variant: ReadingTimerElapsedVariant

    var body: some View {
        timerText
            .font(variant.font)
            .foregroundStyle(.primary)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: state.isRunning && state.isCountdown))
            .lineLimit(1)
            .minimumScaleFactor(variant.minimumScaleFactor)
            .allowsTightening(true)
            .frame(width: variant.width, alignment: variant.frameAlignment)
            .clipped()
            .accessibilityLabel("阅读计时")
            .accessibilityValue(state.elapsedText)
            .invalidatableContent()
    }

    @ViewBuilder
    private var timerText: some View {
        if variant.usesSystemCountdown(for: state) {
            Text(
                timerInterval: state.updatedAt...max(state.timerStartDate, state.updatedAt),
                pauseTime: nil,
                countsDown: true,
                showsHours: state.elapsedSeconds >= 3600
            )
        } else if variant.usesSystemTimer(for: state) {
            Text(state.timerStartDate, style: .timer)
        } else {
            Text(variant.displayText(for: state))
        }
    }
}

private enum ReadingTimerElapsedVariant {
    case compact
    case expanded
    case lockScreen

    var font: Font {
        switch self {
        case .compact:
            return .caption2.weight(.semibold)
        case .expanded:
            return ReadingTimerIslandExpandedMetrics.timerFont
        case .lockScreen:
            return .title3.weight(.semibold)
        }
    }

    var width: CGFloat {
        switch self {
        case .compact:
            return 52
        case .expanded:
            return ReadingTimerIslandExpandedMetrics.elapsedWidth
        case .lockScreen:
            return 100
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .expanded:
            return .leading
        case .compact, .lockScreen:
            return .trailing
        }
    }

    var minimumScaleFactor: CGFloat {
        switch self {
        case .compact:
            return 0.82
        case .lockScreen:
            return 0.86
        case .expanded:
            return 0.86
        }
    }

    func usesSystemTimer(for state: ReadingTimerActivityAttributes.ContentState) -> Bool {
        guard state.isRunning, !state.isCountdown else { return false }
        switch self {
        case .compact, .expanded:
            return state.elapsedSeconds < 3600
        case .lockScreen:
            return true
        }
    }

    func usesSystemCountdown(for state: ReadingTimerActivityAttributes.ContentState) -> Bool {
        guard state.isRunning, state.isCountdown else { return false }
        switch self {
        case .compact, .expanded:
            return state.elapsedSeconds < 3600
        case .lockScreen:
            return true
        }
    }

    func displayText(for state: ReadingTimerActivityAttributes.ContentState) -> String {
        switch self {
        case .compact, .expanded:
            return Self.shortElapsedText(seconds: state.elapsedSeconds)
        case .lockScreen:
            return state.elapsedText
        }
    }

    private static func shortElapsedText(seconds: Int64) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours >= 100 {
            return "99+"
        }
        if hours > 0 {
            return String(format: "%lld:%02lld", hours, minutes)
        }
        return String(format: "%lld:%02lld", minutes, secs)
    }
}

private struct ReadingTimerIslandCover: View {
    let snapshotName: String?
    let remoteURLString: String?
    let bookName: String
    let variant: ReadingTimerIslandCoverVariant

    var body: some View {
        if variant == .expanded {
            expandedCover
                .accessibilityLabel("\(bookName)封面")
        } else {
            standardCover
                .accessibilityLabel("\(bookName)封面")
        }
    }

    private var standardCover: some View {
        coverSurface
            .frame(width: variant.size.width, height: variant.size.height)
            .compositingGroup()
            .clipShape(.rect(cornerRadius: variant.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: variant.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(variant.borderOpacity), lineWidth: variant.borderWidth)
            }
            .shadow(
                color: .black.opacity(variant.shadowOpacity),
                radius: variant.shadowRadius,
                x: 0,
                y: variant.shadowY
            )
            .offset(x: variant.visualOffset.width, y: variant.visualOffset.height)
            .frame(width: variant.safeSize.width, height: variant.safeSize.height)
    }

    private var expandedCover: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: ReadingTimerIslandExpandedMetrics.coverFrameCornerRadius,
                style: .continuous
            )
            .fill(ReadingTimerIslandExpandedMetrics.coverFrameFill)

            coverSurface
                .frame(
                    width: ReadingTimerIslandExpandedMetrics.coverArtSize.width,
                    height: ReadingTimerIslandExpandedMetrics.coverArtSize.height
                )
                .compositingGroup()
                .clipShape(
                    .rect(
                        cornerRadius: ReadingTimerIslandExpandedMetrics.coverArtCornerRadius,
                        style: .continuous
                    )
                )
        }
        .frame(
            width: ReadingTimerIslandExpandedMetrics.coverFrameSize.width,
            height: ReadingTimerIslandExpandedMetrics.coverFrameSize.height
        )
    }

    @ViewBuilder
    private var coverSurface: some View {
        if let localSnapshotImage {
            Image(uiImage: localSnapshotImage)
                .resizable()
                .scaledToFill()
        } else if let remoteCoverURL {
            AsyncImage(url: remoteCoverURL) { phase in
                switch phase {
                case .empty:
                    placeholderCover
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    placeholderCover
                @unknown default:
                    placeholderCover
                }
            }
        } else {
            placeholderCover
        }
    }

    private var placeholderCover: some View {
        ZStack {
            Color(.secondarySystemFill)

            if variant.showsInitials {
                Text(bookInitials)
                    .font(variant.initialsFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var localSnapshotImage: UIImage? {
        guard let snapshotURL = ReadingTimerLiveActivityShared.coverSnapshotURL(snapshotName: snapshotName) else {
            return nil
        }
        return UIImage(contentsOfFile: snapshotURL.path)
    }

    private var remoteCoverURL: URL? {
        guard let remoteURLString,
              let url = URL(string: remoteURLString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file" else {
            return nil
        }
        return url
    }

    private var bookInitials: String {
        let trimmed = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "书" }
        return String(trimmed.prefix(2))
    }
}

private enum ReadingTimerIslandCoverVariant {
    case compact
    case expanded
    case minimal
    case lockScreen

    var size: CGSize {
        switch self {
        case .compact:
            return CGSize(width: 16, height: 20)
        case .expanded:
            return ReadingTimerIslandExpandedMetrics.coverFrameSize
        case .minimal:
            return CGSize(width: 14, height: 18)
        case .lockScreen:
            return CGSize(width: 34, height: 50)
        }
    }

    var safeSize: CGSize {
        switch self {
        case .compact:
            return CGSize(width: 24, height: 28)
        case .expanded:
            return ReadingTimerIslandExpandedMetrics.coverFrameSize
        case .minimal:
            return CGSize(width: 20, height: 22)
        case .lockScreen:
            return size
        }
    }

    var visualOffset: CGSize {
        switch self {
        case .compact, .expanded, .minimal, .lockScreen:
            return .zero
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .compact, .minimal:
            return 3.5
        case .expanded:
            return ReadingTimerIslandExpandedMetrics.coverFrameCornerRadius
        case .lockScreen:
            return 6
        }
    }

    var borderWidth: CGFloat {
        size.width <= 22 ? 0.5 : 0.8
    }

    var borderOpacity: CGFloat {
        switch self {
        case .minimal:
            return 0.18
        case .compact:
            return 0.2
        case .expanded, .lockScreen:
            return 0.24
        }
    }

    var shadowOpacity: CGFloat {
        switch self {
        case .minimal, .compact:
            return 0
        case .expanded, .lockScreen:
            return 0.22
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .minimal, .compact:
            return 0
        case .expanded, .lockScreen:
            return 2.5
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .minimal, .compact:
            return 0
        case .expanded, .lockScreen:
            return 1
        }
    }

    var showsInitials: Bool {
        switch self {
        case .expanded, .lockScreen:
            return true
        case .compact, .minimal:
            return false
        }
    }

    var initialsFont: Font {
        switch self {
        case .expanded:
            return .caption.weight(.semibold)
        case .lockScreen:
            return .caption2.weight(.semibold)
        case .compact, .minimal:
            return .caption2
        }
    }
}

private enum ReadingTimerLiveActivityShared {
    static let appGroupIdentifier = "group.com.merpyzf.xmnote"
    static let coverDirectoryName = "ReadingTimerCovers"

    static func coverSnapshotURL(snapshotName: String?) -> URL? {
        guard let snapshotName, !snapshotName.isEmpty,
              let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
              ) else {
            return nil
        }
        return containerURL
            .appendingPathComponent(coverDirectoryName, isDirectory: true)
            .appendingPathComponent(snapshotName, isDirectory: false)
    }
}
