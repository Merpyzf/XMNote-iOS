/**
 * [INPUT]: 依赖 NoteReviewCardItem、NoteReviewSettings、RichText 共享解析缓存、Nuke 图片管线与设计系统令牌
 * [OUTPUT]: 对外提供 NoteReviewCollectionCell（沉浸/平铺双容器）及页面私有只读富文本和远程图片视图
 * [POS]: Views/Note/Components 的全屏回顾 Cell 层，完整内容只在可见后配置，复用或离屏时取消图片请求
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Nuke
import SwiftUI
import UIKit

enum NoteReviewPresentationMode: Equatable {
    case immersive
    case flat
}

/// 同一个复用 Cell 中保留两套轻重分明的 UIKit 内容容器，布局切换不更换数据源身份。
@MainActor
final class NoteReviewCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "NoteReviewCollectionCell"

    var onFavorite: ((Int64) -> Void)?
    var onOpenImages: ((NoteReviewCardItem, Int) -> Void)?

    private let immersiveContainer = UIView()
    private let immersiveScrollView = UIScrollView()
    private let immersiveStack = UIStackView()
    private let bookLabel = UILabel()
    private let metadataLabel = UILabel()
    private let contentTextView = NoteReviewReadOnlyRichTextView()
    private let ideaSurface = UIView()
    private let ideaTextView = NoteReviewReadOnlyRichTextView()
    private let imageStack = UIStackView()
    private let tagsLabel = UILabel()

    private let flatContainer = UIView()
    private let flatStack = UIStackView()
    private let flatHeaderView = UIView()
    private let flatBookLabel = UILabel()
    private let flatPreviewLabel = UILabel()
    private let flatMetadataLabel = UILabel()
    private let flatImageView = NoteReviewRemoteImageView()
    private let flatFavoriteButton = UIButton(type: .system)
    private var flatImageHeightConstraint: NSLayoutConstraint?

    private let placeholderView = NoteReviewCellPlaceholderView()
    private var configuredNoteID: Int64?
    private var mode: NoteReviewPresentationMode = .immersive
    private var imageViews: [NoteReviewRemoteImageView] = []
    private var representedItem: NoteReviewCardItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildViewHierarchy()
        applyDesignTokens()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedItem = nil
        configuredNoteID = nil
        contentTextView.clear()
        ideaTextView.clear()
        imageViews.forEach { $0.cancel() }
        imageViews.removeAll()
        imageStack.arrangedSubviews.forEach { view in
            imageStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        flatImageView.cancel()
        immersiveScrollView.setContentOffset(.zero, animated: false)
        onFavorite = nil
        onOpenImages = nil
        accessibilityIdentifier = nil
    }

    /// 先绘制与最终模式同尺寸的稳定骨架；完整 HTML 解析不会发生在 dataSource 的 cellForItemAt 中。
    func configurePlaceholder(noteID: Int64, mode: NoteReviewPresentationMode) {
        if configuredNoteID != noteID {
            immersiveScrollView.setContentOffset(.zero, animated: false)
        }
        configuredNoteID = noteID
        representedItem = nil
        self.mode = mode
        immersiveContainer.isHidden = mode != .immersive
        flatContainer.isHidden = mode != .flat
        placeholderView.isHidden = false
        placeholderView.mode = mode
        contentView.backgroundColor = mode == .flat
            ? .secondarySystemGroupedBackground
            : UIColor.clear
        updateFlatSurface(isPlaceholder: true)
        setNeedsLayout()
    }

    /// 在 Cell 已进入可见阶段后配置最终内容，复用身份不匹配时直接丢弃结果。
    func configure(
        item: NoteReviewCardItem,
        mode: NoteReviewPresentationMode,
        settings: NoteReviewSettings,
        flatScale: CGFloat,
        isFavorite: Bool
    ) {
        guard configuredNoteID == item.id else { return }
        representedItem = item
        self.mode = mode
        placeholderView.isHidden = true
        immersiveContainer.isHidden = mode != .immersive
        flatContainer.isHidden = mode != .flat

        switch mode {
        case .immersive:
            configureImmersive(item: item, settings: settings)
        case .flat:
            configureFlat(
                item: item,
                settings: settings,
                scale: flatScale,
                isFavorite: isFavorite
            )
        }
        accessibilityIdentifier = "note-review-\(item.id)"
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hasOverflow = immersiveScrollView.contentSize.height > immersiveScrollView.bounds.height + 1
        immersiveScrollView.isScrollEnabled = mode == .immersive && hasOverflow
    }

    /// 只更新对应书摘的爱心图标，不刷新集合视图快照或其他 Cell。
    func updateFavorite(_ isFavorite: Bool) {
        flatFavoriteButton.configuration = favoriteButtonConfiguration(isFavorite: isFavorite)
        flatFavoriteButton.accessibilityLabel = isFavorite ? "取消收藏" : "收藏"
    }

    /// Cell 离开屏幕后立即终止图片请求；再次显示时按当前目标尺寸重新加载。
    func didEndDisplaying() {
        imageViews.forEach { $0.cancel() }
        flatImageView.cancel()
    }

}

private extension NoteReviewCollectionCell {
    func buildViewHierarchy() {
        contentView.addSubview(immersiveContainer)
        contentView.addSubview(flatContainer)
        contentView.addSubview(placeholderView)
        [immersiveContainer, flatContainer, placeholderView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        immersiveStack.axis = .vertical
        immersiveStack.spacing = 18
        immersiveStack.alignment = .fill
        immersiveStack.translatesAutoresizingMaskIntoConstraints = false
        immersiveScrollView.translatesAutoresizingMaskIntoConstraints = false
        immersiveScrollView.alwaysBounceVertical = true
        immersiveScrollView.showsVerticalScrollIndicator = false
        immersiveScrollView.contentInsetAdjustmentBehavior = .never
        immersiveScrollView.keyboardDismissMode = .interactive
        immersiveContainer.addSubview(immersiveScrollView)
        immersiveScrollView.addSubview(immersiveStack)

        ideaSurface.layer.cornerRadius = 14
        ideaSurface.layer.cornerCurve = .continuous
        ideaTextView.translatesAutoresizingMaskIntoConstraints = false
        ideaSurface.addSubview(ideaTextView)
        NSLayoutConstraint.activate([
            ideaTextView.leadingAnchor.constraint(equalTo: ideaSurface.leadingAnchor, constant: 16),
            ideaTextView.trailingAnchor.constraint(equalTo: ideaSurface.trailingAnchor, constant: -16),
            ideaTextView.topAnchor.constraint(equalTo: ideaSurface.topAnchor, constant: 14),
            ideaTextView.bottomAnchor.constraint(equalTo: ideaSurface.bottomAnchor, constant: -14)
        ])

        imageStack.axis = .horizontal
        imageStack.spacing = 8
        imageStack.distribution = .fillEqually
        imageStack.heightAnchor.constraint(equalToConstant: 148).isActive = true

        immersiveStack.addArrangedSubview(bookLabel)
        immersiveStack.addArrangedSubview(metadataLabel)
        immersiveStack.addArrangedSubview(contentTextView)
        immersiveStack.addArrangedSubview(ideaSurface)
        immersiveStack.addArrangedSubview(imageStack)
        immersiveStack.addArrangedSubview(tagsLabel)

        flatStack.axis = .vertical
        flatStack.spacing = 9
        flatStack.translatesAutoresizingMaskIntoConstraints = false
        flatContainer.addSubview(flatStack)
        flatHeaderView.addSubview(flatBookLabel)
        flatHeaderView.addSubview(flatFavoriteButton)
        flatHeaderView.translatesAutoresizingMaskIntoConstraints = false
        flatBookLabel.translatesAutoresizingMaskIntoConstraints = false
        flatFavoriteButton.translatesAutoresizingMaskIntoConstraints = false
        flatFavoriteButton.addTarget(self, action: #selector(handleFavorite), for: .touchUpInside)

        flatImageHeightConstraint = flatImageView.heightAnchor.constraint(equalToConstant: 56)
        flatImageHeightConstraint?.isActive = true
        flatStack.addArrangedSubview(flatHeaderView)
        flatStack.addArrangedSubview(flatPreviewLabel)
        flatStack.addArrangedSubview(flatImageView)
        flatStack.addArrangedSubview(flatMetadataLabel)

        let readableWidth = immersiveStack.widthAnchor.constraint(lessThanOrEqualToConstant: 680)
        readableWidth.priority = .required
        NSLayoutConstraint.activate([
            immersiveContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            immersiveContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            immersiveContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            immersiveContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            immersiveScrollView.leadingAnchor.constraint(equalTo: immersiveContainer.leadingAnchor),
            immersiveScrollView.trailingAnchor.constraint(equalTo: immersiveContainer.trailingAnchor),
            immersiveScrollView.topAnchor.constraint(equalTo: immersiveContainer.topAnchor),
            immersiveScrollView.bottomAnchor.constraint(equalTo: immersiveContainer.bottomAnchor),
            immersiveScrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: immersiveScrollView.frameLayoutGuide.widthAnchor
            ),
            immersiveScrollView.contentLayoutGuide.heightAnchor.constraint(
                greaterThanOrEqualTo: immersiveScrollView.frameLayoutGuide.heightAnchor
            ),
            immersiveStack.centerXAnchor.constraint(equalTo: immersiveScrollView.contentLayoutGuide.centerXAnchor),
            immersiveStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: immersiveScrollView.contentLayoutGuide.leadingAnchor,
                constant: 28
            ),
            immersiveStack.trailingAnchor.constraint(
                lessThanOrEqualTo: immersiveScrollView.contentLayoutGuide.trailingAnchor,
                constant: -28
            ),
            immersiveStack.topAnchor.constraint(
                equalTo: immersiveScrollView.contentLayoutGuide.topAnchor,
                constant: 104
            ),
            immersiveStack.bottomAnchor.constraint(
                equalTo: immersiveScrollView.contentLayoutGuide.bottomAnchor,
                constant: -98
            ),
            readableWidth,

            flatContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            flatContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            flatContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            flatContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            flatStack.leadingAnchor.constraint(equalTo: flatContainer.leadingAnchor, constant: 16),
            flatStack.trailingAnchor.constraint(equalTo: flatContainer.trailingAnchor, constant: -16),
            flatStack.topAnchor.constraint(equalTo: flatContainer.topAnchor, constant: 16),
            flatStack.bottomAnchor.constraint(lessThanOrEqualTo: flatContainer.bottomAnchor, constant: -14),
            flatHeaderView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: InteractionMetrics.minimumTouchTarget
            ),
            flatBookLabel.leadingAnchor.constraint(equalTo: flatHeaderView.leadingAnchor),
            flatBookLabel.trailingAnchor.constraint(lessThanOrEqualTo: flatFavoriteButton.leadingAnchor, constant: -4),
            flatBookLabel.centerYAnchor.constraint(equalTo: flatHeaderView.centerYAnchor),
            flatFavoriteButton.topAnchor.constraint(equalTo: flatHeaderView.topAnchor),
            flatFavoriteButton.trailingAnchor.constraint(equalTo: flatHeaderView.trailingAnchor),
            flatFavoriteButton.widthAnchor.constraint(
                equalToConstant: InteractionMetrics.minimumTouchTarget
            ),
            flatFavoriteButton.heightAnchor.constraint(
                equalToConstant: InteractionMetrics.minimumTouchTarget
            ),

            placeholderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            placeholderView.topAnchor.constraint(equalTo: contentView.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    func applyDesignTokens() {
        contentView.layer.masksToBounds = false
        bookLabel.font = ReadingContentTypography.uiAnnotationSemibold
        bookLabel.textColor = .label
        bookLabel.numberOfLines = 2
        metadataLabel.font = ReadingContentTypography.uiMetadata
        metadataLabel.textColor = .secondaryLabel
        metadataLabel.numberOfLines = 2
        tagsLabel.font = ReadingContentTypography.uiMetadata
        tagsLabel.textColor = .secondaryLabel
        tagsLabel.numberOfLines = 2

        flatBookLabel.font = ReadingContentTypography.uiMetadataMedium
        flatBookLabel.textColor = .label
        flatBookLabel.numberOfLines = 2
        flatBookLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        flatPreviewLabel.font = ReadingContentTypography.uiAnnotation
        flatPreviewLabel.textColor = .label
        flatPreviewLabel.numberOfLines = 3
        flatPreviewLabel.lineBreakMode = .byTruncatingTail
        flatMetadataLabel.font = ReadingContentTypography.uiMetadata
        flatMetadataLabel.textColor = .secondaryLabel
        flatMetadataLabel.numberOfLines = 1
        flatImageView.layer.cornerRadius = 10
        flatImageView.layer.cornerCurve = .continuous
        flatImageView.clipsToBounds = true
    }

    func configureImmersive(item: NoteReviewCardItem, settings: NoteReviewSettings) {
        contentView.backgroundColor = UIColor.clear
        contentView.layer.cornerRadius = 0
        contentView.layer.shadowOpacity = 0
        let display = settings.immersiveDisplay
        let bodyFont = settings.fontSelection.uiFont(base: ReadingContentTypography.uiBody)
        let annotationFont = settings.fontSelection.uiFont(base: ReadingContentTypography.uiAnnotation)
        let bodyColor = UIColor.label
        let secondaryColor = UIColor.secondaryLabel

        bookLabel.text = item.bookAuthor.isEmpty
            ? item.bookTitle
            : "\(item.bookTitle) · \(item.bookAuthor)"
        bookLabel.isHidden = !display.showsBookInfo || item.bookTitle.isEmpty
        metadataLabel.text = metadataText(item: item, display: display)
        metadataLabel.isHidden = metadataLabel.text?.isEmpty != false
        contentTextView.update(
            html: item.contentHTML,
            baseFont: bodyFont,
            textColor: bodyColor,
            lineSpacing: ReadingContentTypography.bodyLineSpacing,
            alignment: settings.textAlignment.nsTextAlignment
        )

        ideaSurface.backgroundColor = UIColor.tertiarySystemGroupedBackground.withAlphaComponent(0.72)
        ideaSurface.isHidden = !display.showsIdea || item.ideaHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !ideaSurface.isHidden {
            ideaTextView.update(
                html: item.ideaHTML,
                baseFont: annotationFont,
                textColor: secondaryColor,
                lineSpacing: ReadingContentTypography.annotationLineSpacing,
                alignment: settings.textAlignment.nsTextAlignment
            )
        }

        configureImages(item: item, isVisible: display.showsImages)
        tagsLabel.text = item.tags.map(\.title).joined(separator: "  ·  ")
        tagsLabel.isHidden = !display.showsTags || item.tags.isEmpty
    }

    func configureFlat(
        item: NoteReviewCardItem,
        settings: NoteReviewSettings,
        scale: CGFloat,
        isFavorite: Bool
    ) {
        updateFlatSurface(isPlaceholder: false)
        let usesAccessibilityText = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let isDistant = scale < 0.82
        let isNear = scale >= 0.95 && !usesAccessibilityText
        flatStack.spacing = isDistant ? 6 : 9
        flatPreviewLabel.numberOfLines = usesAccessibilityText
            ? 1
            : (scale >= 1.15 ? 4 : (scale < 0.72 ? 2 : 3))
        flatBookLabel.text = item.bookTitle.isEmpty ? "未命名书籍" : item.bookTitle
        var previewParts = [RichTextPlainTextExtractor.plainText(from: item.contentHTML)]
        if settings.immersiveDisplay.showsIdea,
           !item.ideaHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            previewParts.append(RichTextPlainTextExtractor.plainText(from: item.ideaHTML))
        }
        flatPreviewLabel.text = previewParts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        flatPreviewLabel.textAlignment = settings.textAlignment.auxiliaryNSTextAlignment
        flatMetadataLabel.text = compactMetadataText(
            item: item,
            display: settings.immersiveDisplay
        )
        flatMetadataLabel.isHidden = !isNear || flatMetadataLabel.text?.isEmpty != false
        flatImageView.isHidden = !isNear
            || !settings.immersiveDisplay.showsImages
            || item.imageURLs.isEmpty
        if let firstImageURL = item.imageURLs.first, !flatImageView.isHidden {
            flatImageView.load(rawURL: firstImageURL, targetSize: CGSize(width: 180, height: 56), priority: .low)
            flatImageView.accessibilityLabel = item.imageURLs.count > 1 ? "\(item.imageURLs.count) 张图片" : "书摘图片"
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleFlatImageTap))
            flatImageView.gestureRecognizers?.forEach { flatImageView.removeGestureRecognizer($0) }
            flatImageView.addGestureRecognizer(tap)
            flatImageView.isUserInteractionEnabled = true
        } else {
            flatImageView.cancel()
        }
        flatBookLabel.isHidden = usesAccessibilityText
            || scale < 0.75
            || !settings.immersiveDisplay.showsBookInfo
        updateFavorite(isFavorite)
    }

    func configureImages(item: NoteReviewCardItem, isVisible: Bool) {
        imageViews.forEach { $0.cancel() }
        imageViews.removeAll()
        imageStack.arrangedSubviews.forEach { view in
            imageStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        imageStack.isHidden = !isVisible || item.imageURLs.isEmpty
        guard !imageStack.isHidden else { return }
        for (index, rawURL) in item.imageURLs.prefix(3).enumerated() {
            let imageView = NoteReviewRemoteImageView()
            imageView.layer.cornerRadius = 12
            imageView.layer.cornerCurve = .continuous
            imageView.clipsToBounds = true
            imageView.tag = index
            imageView.isUserInteractionEnabled = true
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleImageTap(_:))))
            imageView.load(rawURL: rawURL, targetSize: CGSize(width: 240, height: 148), priority: .normal)
            imageView.accessibilityLabel = "查看第 \(index + 1) 张书摘图片"
            imageStack.addArrangedSubview(imageView)
            imageViews.append(imageView)
        }
    }

    func updateFlatSurface(isPlaceholder: Bool) {
        guard mode == .flat else { return }
        contentView.layer.cornerRadius = 20
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderWidth = 0.5
        contentView.layer.borderColor = UIColor.separator.withAlphaComponent(0.72).cgColor
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = isPlaceholder ? 0 : 0.08
        contentView.layer.shadowRadius = 12
        contentView.layer.shadowOffset = CGSize(width: 0, height: 5)
        contentView.backgroundColor = .secondarySystemGroupedBackground
    }

    func metadataText(item: NoteReviewCardItem, display: NoteReviewImmersiveDisplaySettings) -> String {
        var values: [String] = []
        if display.showsChapter, !item.chapterTitle.isEmpty { values.append(item.chapterTitle) }
        if display.showsPosition, !item.position.isEmpty { values.append(item.position) }
        if display.showsCreatedDate, item.createdDate > 0 {
            values.append(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(item.createdDate) / 1000)))
        }
        return values.joined(separator: "  ·  ")
    }

    func compactMetadataText(
        item: NoteReviewCardItem,
        display: NoteReviewImmersiveDisplaySettings
    ) -> String {
        var values: [String] = []
        if display.showsChapter, !item.chapterTitle.isEmpty { values.append(item.chapterTitle) }
        if display.showsPosition, !item.position.isEmpty { values.append(item.position) }
        if display.showsCreatedDate, item.createdDate > 0 {
            values.append(
                Self.dateFormatter.string(
                    from: Date(timeIntervalSince1970: TimeInterval(item.createdDate) / 1000)
                )
            )
        }
        if display.showsTags, !item.tags.isEmpty {
            values.append(item.tags.map(\.title).joined(separator: " · "))
        }
        return values.joined(separator: " · ")
    }

    func favoriteButtonConfiguration(isFavorite: Bool) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: isFavorite ? "heart.fill" : "heart")
        configuration.baseForegroundColor = isFavorite
            ? .systemRed
            : .secondaryLabel
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        return configuration
    }

    @objc func handleFavorite() {
        guard let noteID = representedItem?.id else { return }
        onFavorite?(noteID)
    }

    @objc func handleImageTap(_ recognizer: UITapGestureRecognizer) {
        guard let representedItem, let index = recognizer.view?.tag else { return }
        onOpenImages?(representedItem, index)
    }

    @objc func handleFlatImageTap() {
        guard let representedItem else { return }
        onOpenImages?(representedItem, 0)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// 直接复用 RichText 解析缓存的只读 TextKit 视图，内部永不纵向滚动。
@MainActor
private final class NoteReviewReadOnlyRichTextView: UITextView {
    private var contentSignature = ""

    init() {
        let layoutManager = RichTextLayoutManager()
        layoutManager.bulletColor = .label
        layoutManager.quoteColor = .secondaryLabel
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        adjustsFontForContentSizeCategory = true
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        alignment: NSTextAlignment
    ) {
        let signature = "\(html.hashValue)|\(baseFont.fontName)|\(baseFont.pointSize)|\(lineSpacing)|\(alignment.rawValue)|\(traitCollection.userInterfaceStyle.rawValue)"
        guard signature != contentSignature else { return }
        contentSignature = signature
        textStorage.setAttributedString(
            RichText.resolvedAttributedString(
                html: html,
                baseFont: baseFont,
                textColor: textColor,
                lineSpacing: lineSpacing,
                textAlignment: alignment,
                traitCollection: traitCollection
            )
        )
        invalidateIntrinsicContentSize()
    }

    func clear() {
        contentSignature = ""
        textStorage.setAttributedString(NSAttributedString())
        invalidateIntrinsicContentSize()
    }
}

/// 使用项目统一 Nuke 请求构造器的页面私有图片视图，按目标点尺寸降采样并支持复用取消。
@MainActor
private final class NoteReviewRemoteImageView: UIImageView {
    private var loadingTask: Task<Void, Never>?
    private var representedURL: URL?

    init() {
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        backgroundColor = .tertiarySystemGroupedBackground
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(rawURL: String, targetSize: CGSize, priority: XMImageRequestBuilder.Priority) {
        guard let url = XMImageRequestBuilder.normalizedURL(from: rawURL) else {
            cancel()
            return
        }
        guard representedURL != url || image == nil else { return }
        cancel()
        representedURL = url
        let request = XMImageLoadRequest(url: url, priority: priority, targetSizeInPoints: targetSize)
        loadingTask = Task { [weak self] in
            do {
                let loadedImage = try await ImagePipeline.shared.image(for: request.imageRequest)
                guard !Task.isCancelled, self?.representedURL == url else { return }
                self?.image = loadedImage
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func cancel() {
        loadingTask?.cancel()
        loadingTask = nil
        representedURL = nil
        image = nil
    }
}

/// 与最终布局等尺寸的静态骨架，加载慢于滚动时保持页面稳定且不闪白。
private final class NoteReviewCellPlaceholderView: UIView {
    var mode: NoteReviewPresentationMode = .immersive {
        didSet { setNeedsLayout() }
    }

    private let lines: [UIView] = (0..<5).map { _ in UIView() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        lines.forEach {
            $0.backgroundColor = UIColor.tertiarySystemFill.withAlphaComponent(0.55)
            $0.layer.cornerRadius = 3
            addSubview($0)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = mode == .immersive ? 30 : 16
        let top: CGFloat = mode == .immersive ? 132 : 54
        let available = max(0, bounds.width - inset * 2)
        for (index, line) in lines.enumerated() {
            let factor: CGFloat = index == lines.count - 1 ? 0.62 : 1
            line.frame = CGRect(
                x: inset,
                y: top + CGFloat(index) * 22,
                width: available * factor,
                height: 7
            )
        }
    }
}
