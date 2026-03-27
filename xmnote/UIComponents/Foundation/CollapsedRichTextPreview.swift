/**
 * [INPUT]: 依赖 RichText 的共享 HTML 缓存/预览富文本构建能力、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 CollapsedRichTextPreview（收起态轻量富文本预览组件）
 * [POS]: UIComponents/Foundation 的内部轻量展示组件，服务 ExpandableRichText 的列表收起态性能优化
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
    let onExpand: () -> Void

    /// 创建收起态预览承载视图，列表阶段只保留轻量文本和“展开”按钮。
    func makeUIView(context: Context) -> CollapsedRichTextPreviewView {
        let view = CollapsedRichTextPreviewView()
        view.updateExpandAction(onExpand)
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

        uiView.updateConfiguration(
            maxLines: maxLines,
            onExpand: onExpand
        )
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
            return snapshot.size
        }

        if let snapshot = RichText.cachedLayoutSnapshot(for: layoutKey) {
            context.coordinator.lastLayoutKey = layoutKey
            context.coordinator.lastLayoutSnapshot = snapshot
            uiView.applyLayoutSnapshot(snapshot, width: width)
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
        return snapshot.size
    }

    /// 创建单实例协调器，保存当前内容与布局 key。
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Coordinator 记录当前预览实例最近一次的内容与布局命中状态。
    final class Coordinator {
        var lastContentKey: String = ""
        var lastLayoutKey: String = ""
        var lastLayoutSnapshot: RichTextLayoutSnapshot?
    }
}

/// CollapsedRichTextPreviewView 用 UILabel + 展开按钮承接富文本收起态，替代重型 UITextView。
final class CollapsedRichTextPreviewView: UIView {
    private let label = UILabel()
    private let expandButton = UIButton(type: .system)
    private let sizingLabel = UILabel()
    private let expandButtonSpacing = Spacing.half
    private var layoutWidth: CGFloat = 0
    private var snapshot: RichTextLayoutSnapshot = .init(size: .zero, isTruncated: false)
    private var currentContentKey: String = ""
    private var onExpand: (() -> Void)?

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

    /// 根据缓存快照把正文和“展开”按钮落到最终 frame，避免布局逻辑散落在测量阶段。
    override func layoutSubviews() {
        super.layoutSubviews()

        let width = bounds.width > 0 ? bounds.width : layoutWidth
        guard width > 0 else { return }

        let buttonSize = measuredButtonSize(fittingWidth: width)
        let buttonHeight = snapshot.isTruncated ? buttonSize.height : 0
        let spacing = snapshot.isTruncated ? expandButtonSpacing : 0
        let textHeight = max(0, snapshot.size.height - buttonHeight - spacing)

        label.frame = CGRect(x: 0, y: 0, width: width, height: textHeight)

        if snapshot.isTruncated {
            expandButton.isHidden = false
            expandButton.frame = CGRect(
                x: max(0, width - buttonSize.width),
                y: textHeight + expandButtonSpacing,
                width: buttonSize.width,
                height: buttonHeight
            )
        } else {
            expandButton.isHidden = true
            expandButton.frame = .zero
        }
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
        onExpand: @escaping () -> Void
    ) {
        if label.numberOfLines != maxLines {
            label.numberOfLines = maxLines
        }
        updateExpandAction(onExpand)
    }

    /// 更新展开回调，保持 SwiftUI 闭包和 UIKit 按钮目标一致。
    func updateExpandAction(_ onExpand: @escaping () -> Void) {
        self.onExpand = onExpand
    }

    /// 测量正文和“展开”按钮组合后的总高度，供列表收起态直接复用。
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
        let buttonHeight = isTruncated ? measuredButtonSize(fittingWidth: width).height : 0
        let totalHeight = limitedHeight + (isTruncated ? expandButtonSpacing + buttonHeight : 0)

        return RichTextLayoutSnapshot(
            size: CGSize(width: width, height: totalHeight),
            isTruncated: isTruncated
        )
    }

    /// 应用缓存测量结果并触发重排，保证视图和布局系统使用同一快照。
    func applyLayoutSnapshot(_ snapshot: RichTextLayoutSnapshot, width: CGFloat) {
        self.snapshot = snapshot
        layoutWidth = width
        expandButton.isHidden = !snapshot.isTruncated
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// 封装setupSubviews对应的业务步骤，确保调用方可以稳定复用该能力。
    private func setupSubviews() {
        backgroundColor = .clear

        label.backgroundColor = .clear
        label.numberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        label.allowsDefaultTighteningForTruncation = true
        if #available(iOS 14.0, *) {
            label.lineBreakStrategy = .standard
        }
        label.isUserInteractionEnabled = false
        addSubview(label)

        sizingLabel.backgroundColor = .clear
        sizingLabel.numberOfLines = 0
        sizingLabel.lineBreakMode = .byWordWrapping
        sizingLabel.allowsDefaultTighteningForTruncation = true
        if #available(iOS 14.0, *) {
            sizingLabel.lineBreakStrategy = .standard
        }

        expandButton.setTitle("展开", for: .normal)
        expandButton.setTitleColor(UIColor(Color.brand), for: .normal)
        expandButton.titleLabel?.font = .preferredFont(forTextStyle: .caption2).weight(.medium)
        expandButton.contentHorizontalAlignment = .right
        expandButton.addTarget(self, action: #selector(handleExpandTapped), for: .touchUpInside)
        addSubview(expandButton)
    }

    /// 执行measuredTextHeight对应的数据处理步骤，并返回当前流程需要的结果。
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

    /// 执行measuredButtonSize对应的数据处理步骤，并返回当前流程需要的结果。
    private func measuredButtonSize(fittingWidth width: CGFloat) -> CGSize {
        let rawSize = expandButton.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: ceil(rawSize.width), height: ceil(rawSize.height))
    }

    @objc
    /// 处理handleExpandTapped对应的状态流转，确保交互过程与数据状态保持一致。
    private func handleExpandTapped() {
        onExpand?()
    }
}

private extension UIFont {
    /// 在保留字号的前提下生成指定字重字体，供“展开”按钮轻量定制系统字体。
    func weight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
