/**
 * [INPUT]: 依赖 RichText 的共享 HTML 缓存/预览富文本构建能力、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 CollapsedRichTextPreview（收起态轻量富文本测量与展示组件）
 * [POS]: UIComponents/Media/RichText 的内部轻量展示组件，只负责预览文本，展开控件由 ExpandableRichText 承载
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 收起态轻量富文本预览。
/// 使用 UILabel 做静态富文本展示，列表与引用在预览阶段退化为普通段落。
struct CollapsedRichTextPreview: UIViewRepresentable {
    let html: String
    let baseFont: UIFont
    let textColor: UIColor
    let lineSpacing: CGFloat
    let maxLines: Int
    let onContentTap: (() -> Void)?
    let onTruncationChanged: ((Bool) -> Void)?

    /// 构建收起态富文本预览，并把真实溢出状态交给外层决定是否展示操作入口。
    init(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        maxLines: Int,
        onContentTap: (() -> Void)? = nil,
        onTruncationChanged: ((Bool) -> Void)? = nil
    ) {
        self.html = html
        self.baseFont = baseFont
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.maxLines = maxLines
        self.onContentTap = onContentTap
        self.onTruncationChanged = onTruncationChanged
    }

    /// 创建收起态预览承载视图，列表阶段只保留轻量文本。
    func makeUIView(context: Context) -> CollapsedRichTextPreviewView {
        let view = CollapsedRichTextPreviewView()
        view.updateContentTapAction(onContentTap)
        return view
    }

    /// 仅在 HTML 或主题签名变化时刷新预览内容，降低滚动中的 UILabel 重排成本。
    func updateUIView(_ uiView: CollapsedRichTextPreviewView, context: Context) {
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
            uiView.updateAttributedText(attributed, contentKey: contentKey)
        }

        uiView.updateConfiguration(maxLines: maxLines, onContentTap: onContentTap)
    }

    /// 结合共享缓存测量收起态高度，避免同一内容在列表里重复计算。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: CollapsedRichTextPreviewView,
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
            reportTruncationIfNeeded(snapshot.isTruncated, context: context)
            return snapshot.size
        }

        if let snapshot = RichText.cachedLayoutSnapshot(for: layoutKey) {
            context.coordinator.lastLayoutKey = layoutKey
            context.coordinator.lastLayoutSnapshot = snapshot
            uiView.applyLayoutSnapshot(snapshot, width: width)
            reportTruncationIfNeeded(snapshot.isTruncated, context: context)
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
        reportTruncationIfNeeded(snapshot.isTruncated, context: context)
        return snapshot.size
    }

    /// 创建单实例协调器，保存当前内容与布局 key。
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Coordinator 记录当前预览实例最近一次的内容与布局命中状态。
    final class Coordinator {
        var lastContentKey: String = ""
        var lastLayoutKey: String = ""
        var lastLayoutSnapshot: RichTextLayoutSnapshot?
        var lastReportedTruncation: Bool?
    }

    private func reportTruncationIfNeeded(_ isTruncated: Bool, context: Context) {
        guard context.coordinator.lastReportedTruncation != isTruncated else { return }
        context.coordinator.lastReportedTruncation = isTruncated
        guard let onTruncationChanged else { return }
        DispatchQueue.main.async {
            onTruncationChanged(isTruncated)
        }
    }
}

/// CollapsedRichTextPreviewView 用 UILabel 承接富文本收起态，替代重型 UITextView。
final class CollapsedRichTextPreviewView: UIView {
    private let label = UILabel()
    private let sizingLabel = UILabel()
    private var layoutWidth: CGFloat = 0
    private var snapshot: RichTextLayoutSnapshot = .init(size: .zero, isTruncated: false)
    private var currentContentKey: String = ""
    private var onContentTap: (() -> Void)?

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

    /// 根据缓存快照把预览正文落到最终 frame，展开控件由 SwiftUI 外层独立布局。
    override func layoutSubviews() {
        super.layoutSubviews()

        let width = bounds.width > 0 ? bounds.width : layoutWidth
        guard width > 0 else { return }
        label.frame = CGRect(x: 0, y: 0, width: width, height: snapshot.size.height)
    }

    /// 仅在 HTML 或排版相关 key 变化时更新 label 内容，减少滚动时的重复布局。
    func updateAttributedText(_ attributedText: NSAttributedString, contentKey: String) {
        guard currentContentKey != contentKey else { return }
        currentContentKey = contentKey
        label.attributedText = attributedText
    }

    /// 收起态配置独立更新，避免每次 SwiftUI 刷新都重设 attributedText。
    func updateConfiguration(
        maxLines: Int,
        onContentTap: (() -> Void)?
    ) {
        if label.numberOfLines != maxLines {
            label.numberOfLines = maxLines
        }
        updateContentTapAction(onContentTap)
    }

    /// 更新正文点击回调；手势仅挂在 UILabel 上，不与外层展开按钮竞争。
    func updateContentTapAction(_ onContentTap: (() -> Void)?) {
        self.onContentTap = onContentTap
    }

    /// 测量限定行数正文高度与真实溢出状态，供外层组合独立操作按钮。
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
        let isTruncated = unlimitedHeight - limitedHeight > 0.5
        return RichTextLayoutSnapshot(
            size: CGSize(width: width, height: limitedHeight),
            isTruncated: isTruncated
        )
    }

    /// 应用缓存测量结果并触发重排，保证视图和布局系统使用同一快照。
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
        label.isUserInteractionEnabled = true
        let contentTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleContentTapped))
        label.addGestureRecognizer(contentTapGesture)
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
        let bounds = CGRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)
        let rect = sizingLabel.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
        return ceil(max(0, rect.height))
    }

    @objc
    private func handleContentTapped() {
        onContentTap?()
    }
}
