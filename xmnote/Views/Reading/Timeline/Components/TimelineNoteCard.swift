/**
 * [INPUT]: 依赖 TimelineNoteEvent 数据模型、CardContainer 容器、DesignTokens 设计令牌、RichText 富文本、XMJXImageWall/XMJXGalleryItem 图片墙
 * [OUTPUT]: 对外提供 TimelineNoteCard（时间线书摘卡片）
 * [POS]: Reading/Timeline 页面私有子视图，渲染书摘头部、HTML 正文、用户批注、附图墙与标签横滑区
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线书摘卡片，展示专属头部、可展开摘录、想法引用块、附图墙与标签横滑区。
struct TimelineNoteCard: View {
    let event: TimelineNoteEvent
    let timestamp: Int64
    let bookName: String

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                header

                divider

                excerptSection

                if !event.idea.isEmpty {
                    ideaSection
                }

                if !event.imageURLs.isEmpty {
                    imageWall
                }

                if !event.tagNames.isEmpty {
                    tagsSection
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.cozy) {
            Image(systemName: "note.text")
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.brand)

            Text("《\(displayBookName)》")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
                .lineLimit(1)

            Spacer(minLength: Spacing.cozy)

            Text(timeString)
                .font(AppTypography.caption)
                .monospacedDigit()
                .foregroundStyle(Color.textHint)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.surfaceBorderDefault.opacity(0.55))
            .frame(height: 1)
    }

    // MARK: - Excerpt

    @ViewBuilder
    private var excerptSection: some View {
        if !event.content.isEmpty {
            TimelineExpandableNoteText(
                html: event.content,
                textColor: .label
            )
        }
    }

    // MARK: - Idea

    private var ideaSection: some View {
        TimelineExpandableNoteText(
            html: event.idea,
            baseFont: TimelineTypography.eventRichTextBaseFont,
            textColor: UIColor(Color.textSecondary),
            lineSpacing: TimelineTypography.eventRichTextLineSpacing
        )
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.half)
        .background(
            Color.controlFillSecondary.opacity(0.55),
            in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
        )
    }

    // MARK: - Image Wall

    private var imageWall: some View {
        XMJXImageWall(
            items: event.imageURLs.enumerated().map { index, url in
                XMJXGalleryItem(id: "note-img-\(index)", thumbnailURL: url, originalURL: url)
            },
            columnCount: event.imageURLs.count == 1 ? 1 : 3
        )
    }

    // MARK: - Tags

    private var tagsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.tight) {
                ForEach(Array(event.tagNames.enumerated()), id: \.offset) { _, tag in
                    Text(tag)
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.compact)
                        .background(Color.tagBackground, in: Capsule())
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var displayBookName: String {
        let trimmed = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let fallback = event.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "未命名书籍" : fallback
    }

    private var timeString: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        return Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct TimelineExpandableNoteText: View, Equatable {
    let html: String
    var baseFont: UIFont = TimelineTypography.eventRichTextBaseFont
    var textColor: UIColor = .label
    var lineSpacing: CGFloat = TimelineTypography.eventRichTextLineSpacing
    var actionColor: Color = Color.brand.opacity(0.82)
    var maxLines: Int = 3

    @State private var isExpanded = false
    @State private var isTruncated = false

    static func == (lhs: TimelineExpandableNoteText, rhs: TimelineExpandableNoteText) -> Bool {
        lhs.html == rhs.html &&
        lhs.baseFont == rhs.baseFont &&
        lhs.textColor == rhs.textColor &&
        lhs.lineSpacing == rhs.lineSpacing &&
        lhs.actionColor == rhs.actionColor &&
        lhs.maxLines == rhs.maxLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Group {
                if isExpanded {
                    TimelineExpandedNoteBody(
                        html: html,
                        baseFont: baseFont,
                        textColor: textColor,
                        lineSpacing: lineSpacing
                    )
                } else {
                    TimelineCollapsedNotePreview(
                        html: html,
                        baseFont: baseFont,
                        textColor: textColor,
                        lineSpacing: lineSpacing,
                        maxLines: maxLines,
                        onTruncationChanged: { truncated in
                            guard truncated != isTruncated else { return }
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                isTruncated = truncated
                            }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .transition(.identity)

            if isTruncated {
                HStack {
                    Spacer()

                    Button {
                        withAnimation(.snappy) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Text(isExpanded ? "收起" : "展开")
                            .font(AppTypography.caption2Medium)
                            .foregroundStyle(actionColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct TimelineExpandedNoteBody: UIViewRepresentable {
    let html: String
    let baseFont: UIFont
    let textColor: UIColor
    let lineSpacing: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let layoutManager = RichTextLayoutManager()
        layoutManager.bulletColor = UIColor.label
        layoutManager.quoteColor = UIColor.systemGreen

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = NSLineBreakMode.byWordWrapping
        layoutManager.addTextContainer(textContainer)

        let textView = UITextView(frame: CGRect.zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = UIColor.clear
        textView.textContainerInset = UIEdgeInsets.zero
        textView.contentInset = UIEdgeInsets.zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(
            UILayoutPriority.required,
            for: NSLayoutConstraint.Axis.vertical
        )
        textView.setContentHuggingPriority(
            UILayoutPriority.required,
            for: NSLayoutConstraint.Axis.vertical
        )
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let traitCollection = textView.traitCollection
        let contentKey = RichText.contentCacheKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )

        guard context.coordinator.lastContentKey != contentKey else { return }
        context.coordinator.lastContentKey = contentKey
        context.coordinator.lastLayoutKey = ""
        context.coordinator.lastLayoutSnapshot = nil

        let attributed = RichText.resolvedAttributedString(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        textView.textStorage.setAttributedString(attributed)
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let screenWidth = uiView.window?.screen.bounds.width ?? 390
        let width = proposal.width ?? screenWidth
        guard width > 0, width.isFinite else { return nil }

        let traitCollection = uiView.traitCollection
        let contentKey = RichText.contentCacheKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        let scale = uiView.window?.screen.scale ?? max(traitCollection.displayScale, 1)
        let layoutKey = "timeline-expanded|" + RichText.layoutCacheKey(
            contentKey: contentKey,
            maxLines: 0,
            width: width,
            screenScale: scale
        )

        if context.coordinator.lastLayoutKey == layoutKey,
           let snapshot = context.coordinator.lastLayoutSnapshot {
            return snapshot.size
        }

        if let snapshot = RichText.cachedLayoutSnapshot(for: layoutKey) {
            context.coordinator.lastLayoutKey = layoutKey
            context.coordinator.lastLayoutSnapshot = snapshot
            return snapshot.size
        }

        let textContainer = uiView.textContainer
        let layoutManager = uiView.layoutManager
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = NSLineBreakMode.byWordWrapping
        textContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        uiView.bounds.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let height = ceil(max(0, usedRect.integral.height))
        let snapshot = RichTextLayoutSnapshot(
            size: CGSize(width: width, height: height),
            isTruncated: false
        )
        RichText.storeLayoutSnapshot(snapshot, for: layoutKey)
        context.coordinator.lastLayoutKey = layoutKey
        context.coordinator.lastLayoutSnapshot = snapshot
        _ = glyphRange
        return snapshot.size
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastContentKey: String = ""
        var lastLayoutKey: String = ""
        var lastLayoutSnapshot: RichTextLayoutSnapshot?
    }
}

private struct TimelineCollapsedNotePreview: UIViewRepresentable {
    let html: String
    let baseFont: UIFont
    let textColor: UIColor
    let lineSpacing: CGFloat
    let maxLines: Int
    let onTruncationChanged: (Bool) -> Void

    func makeUIView(context: Context) -> TimelineCollapsedNotePreviewView {
        TimelineCollapsedNotePreviewView()
    }

    func updateUIView(_ uiView: TimelineCollapsedNotePreviewView, context: Context) {
        let traitCollection = uiView.traitCollection
        let contentKey = RichText.previewContentKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )

        if context.coordinator.lastContentKey != contentKey {
            context.coordinator.lastContentKey = contentKey
            context.coordinator.lastLayoutKey = ""
            context.coordinator.lastLayoutSnapshot = nil
            let attributed = RichText.resolvedPreviewAttributedString(
                html: html,
                baseFont: baseFont,
                textColor: textColor,
                lineSpacing: lineSpacing,
                traitCollection: traitCollection
            )
            uiView.updateAttributedText(attributed, contentKey: contentKey, maxLines: maxLines)
        } else {
            uiView.updateMaxLines(maxLines)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: TimelineCollapsedNotePreviewView,
        context: Context
    ) -> CGSize? {
        let screenWidth = uiView.window?.screen.bounds.width ?? 390
        let width = proposal.width ?? screenWidth
        guard width > 0, width.isFinite else { return nil }

        let traitCollection = uiView.traitCollection
        let contentKey = RichText.previewContentKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        let scale = uiView.window?.screen.scale ?? max(traitCollection.displayScale, 1)
        let layoutKey = RichText.layoutCacheKey(
            contentKey: contentKey,
            maxLines: maxLines,
            width: width,
            screenScale: scale
        )

        if context.coordinator.lastLayoutKey == layoutKey,
           let snapshot = context.coordinator.lastLayoutSnapshot {
            uiView.applyLayoutSnapshot(snapshot, width: width)
            notifyTruncationIfNeeded(snapshot.isTruncated, context: context)
            return snapshot.size
        }

        if let snapshot = RichText.cachedLayoutSnapshot(for: layoutKey) {
            context.coordinator.lastLayoutKey = layoutKey
            context.coordinator.lastLayoutSnapshot = snapshot
            uiView.applyLayoutSnapshot(snapshot, width: width)
            notifyTruncationIfNeeded(snapshot.isTruncated, context: context)
            return snapshot.size
        }

        let attributed = uiView.currentAttributedText ?? RichText.resolvedPreviewAttributedString(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        let snapshot = uiView.measureLayoutSnapshot(
            attributedText: attributed,
            width: width,
            maxLines: maxLines
        )
        RichText.storeLayoutSnapshot(snapshot, for: layoutKey)
        context.coordinator.lastLayoutKey = layoutKey
        context.coordinator.lastLayoutSnapshot = snapshot
        uiView.applyLayoutSnapshot(snapshot, width: width)
        notifyTruncationIfNeeded(snapshot.isTruncated, context: context)
        return snapshot.size
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastContentKey: String = ""
        var lastLayoutKey: String = ""
        var lastLayoutSnapshot: RichTextLayoutSnapshot?
        var lastReportedTruncation: Bool?
    }

    private func notifyTruncationIfNeeded(_ isTruncated: Bool, context: Context) {
        guard context.coordinator.lastReportedTruncation != isTruncated else { return }
        context.coordinator.lastReportedTruncation = isTruncated
        DispatchQueue.main.async {
            onTruncationChanged(isTruncated)
        }
    }
}

private final class TimelineCollapsedNotePreviewView: UIView {
    private let label = UILabel()
    private let sizingLabel = UILabel()
    private var layoutWidth: CGFloat = 0
    private var snapshot: RichTextLayoutSnapshot = .init(size: .zero, isTruncated: false)
    private var currentContentKey: String = ""

    var currentAttributedText: NSAttributedString? {
        label.attributedText
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        snapshot.size
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width > 0 ? bounds.width : layoutWidth
        guard width > 0 else { return }
        label.frame = CGRect(origin: .zero, size: CGSize(width: width, height: snapshot.size.height))
    }

    func updateAttributedText(_ attributedText: NSAttributedString, contentKey: String, maxLines: Int) {
        guard currentContentKey != contentKey else { return }
        currentContentKey = contentKey
        label.attributedText = attributedText
        label.numberOfLines = maxLines
    }

    func updateMaxLines(_ maxLines: Int) {
        guard label.numberOfLines != maxLines else { return }
        label.numberOfLines = maxLines
    }

    func measureLayoutSnapshot(
        attributedText: NSAttributedString,
        width: CGFloat,
        maxLines: Int
    ) -> RichTextLayoutSnapshot {
        guard attributedText.length > 0 else {
            return RichTextLayoutSnapshot(size: CGSize(width: width, height: 0), isTruncated: false)
        }

        let limitedHeight = measuredTextHeight(
            attributedText: attributedText,
            width: width,
            numberOfLines: maxLines
        )
        let unlimitedHeight = measuredTextHeight(
            attributedText: attributedText,
            width: width,
            numberOfLines: 0
        )

        return RichTextLayoutSnapshot(
            size: CGSize(width: width, height: limitedHeight),
            isTruncated: unlimitedHeight - limitedHeight > 0.5
        )
    }

    func applyLayoutSnapshot(_ snapshot: RichTextLayoutSnapshot, width: CGFloat) {
        self.snapshot = snapshot
        layoutWidth = width
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func setupSubviews() {
        backgroundColor = .clear

        label.backgroundColor = .clear
        label.numberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        label.allowsDefaultTighteningForTruncation = true
        if #available(iOS 14.0, *) {
            label.lineBreakStrategy = .standard
        }
        addSubview(label)

        sizingLabel.backgroundColor = .clear
        sizingLabel.numberOfLines = 0
        sizingLabel.lineBreakMode = .byWordWrapping
        sizingLabel.allowsDefaultTighteningForTruncation = true
        if #available(iOS 14.0, *) {
            sizingLabel.lineBreakStrategy = .standard
        }
    }

    private func measuredTextHeight(
        attributedText: NSAttributedString,
        width: CGFloat,
        numberOfLines: Int
    ) -> CGFloat {
        sizingLabel.attributedText = attributedText
        sizingLabel.numberOfLines = numberOfLines
        sizingLabel.lineBreakMode = numberOfLines > 0 ? .byTruncatingTail : .byWordWrapping
        let bounds = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let rect = sizingLabel.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
        return ceil(max(0, rect.height))
    }
}

#Preview {
    ZStack {
        Color.surfacePage.ignoresSafeArea()
        ScrollView {
            VStack(spacing: Spacing.base) {
                TimelineNoteCard(
                    event: TimelineNoteEvent(
                        noteId: 1,
                        content: "人生最大的幸运，就是在年富力强时发现了自己的<b>使命</b>。",
                        idea: "这句话让我想到了乔布斯在斯坦福的演讲",
                        bookTitle: "活法",
                        imageURLs: [
                            "https://picsum.photos/200/300",
                            "https://picsum.photos/201/300",
                            "https://picsum.photos/202/300",
                        ],
                        tagNames: ["方法论", "人生", "反复阅读"]
                    ),
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    bookName: "活法"
                )
                TimelineNoteCard(
                    event: TimelineNoteEvent(
                        noteId: 2,
                        content: "我们总是倾向于用最复杂的方式来解决问题，却忽略了最简单的途径往往就在眼前。",
                        idea: "",
                        bookTitle: "思考快与慢",
                        imageURLs: [],
                        tagNames: []
                    ),
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    bookName: "思考快与慢"
                )
                TimelineNoteCard(
                    event: TimelineNoteEvent(
                        noteId: 3,
                        content: "单图书摘测试",
                        idea: "",
                        bookTitle: "测试",
                        imageURLs: ["https://picsum.photos/400/300"],
                        tagNames: ["单图"]
                    ),
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    bookName: "测试"
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
        }
    }
}
