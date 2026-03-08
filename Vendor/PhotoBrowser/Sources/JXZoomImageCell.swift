//
//  JXZoomImageCell.swift
//  JXPhotoBrowser
//

import UIKit

/// 支持图片捏合缩放查看的 Cell
/// 内部使用 UIScrollView 实现缩放，支持单击关闭、双击切换缩放模式等手势交互
open class JXZoomImageCell: UICollectionViewCell, UIScrollViewDelegate, JXPhotoBrowserCellProtocol {
    // MARK: - Static
    public static let reuseIdentifier = "JXZoomImageCell"
    
    // MARK: - UI
    /// 承载图片并支持捏合缩放的滚动视图
    public let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.minimumZoomScale = 1.0
        sv.maximumZoomScale = 3.0
        sv.bouncesZoom = true
        sv.alwaysBounceVertical = false
        sv.alwaysBounceHorizontal = false
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.decelerationRate = .fast
        sv.backgroundColor = .clear
        return sv
    }()

    /// 展示图片内容的视图（参与缩放与转场）
    public let imageView: UIImageView = {
        let iv = UIImageView()
        // 使用非 AutoLayout 的 frame 布局以配合缩放
        iv.translatesAutoresizingMaskIntoConstraints = true
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        return iv
    }()
    
    // MARK: - Video Properties
    
    /// 双击手势：在初始缩放状态下切换缩放模式（长边铺满 ↔ 短边铺满），在非初始缩放状态下切换回初始状态
    public private(set) lazy var doubleTapGesture: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        g.numberOfTapsRequired = 2
        g.numberOfTouchesRequired = 1
        return g
    }()

    // 单击手势：用于关闭浏览器（与双击互斥）
    public private(set) lazy var singleTapGesture: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        g.numberOfTapsRequired = 1
        g.numberOfTouchesRequired = 1
        g.delaysTouchesBegan = false
        return g
    }()
    
    // MARK: - State
    
    /// 弱引用的浏览器（用于调用关闭）
    public weak var browser: JXPhotoBrowserViewController?
    
    // MARK: - Init
    public override init(frame: CGRect) {
        super.init(frame: frame)
        // ScrollView 承载 imageView 以支持捏合缩放
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        scrollView.delegate = self
        scrollView.addSubview(imageView)
        
        // 添加双击缩放
        scrollView.addGestureRecognizer(doubleTapGesture)
        // 添加单击关闭，并与双击冲突处理
        scrollView.addGestureRecognizer(singleTapGesture)
        singleTapGesture.require(toFail: doubleTapGesture)
        backgroundColor = .clear
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    // MARK: - Layout State
    /// 上一次布局的容器尺寸（用于旋转时重置缩放）
    private var lastBoundsSize: CGSize = .zero
    
    /// 缩放模式：true 表示短边铺满（scaleAspectFill），false 表示长边铺满（scaleAspectFit）
    private var isShortEdgeFit: Bool = false

    /// 下拉关闭交互进行中时，锁定内部缩放/布局校正，避免与外层手势产生竞态。
    private(set) var isDismissInteracting: Bool = false

    /// 双击缩放动画完成后执行一次归一化，替代固定时长延迟。
    private var pendingNormalizeAfterZoomAnimation: Bool = false

    /// 缩放收敛判定容差。
    private let zoomEpsilon: CGFloat = 0.01

    /// 最小态归一化动画时长（无弹簧，强调可预期收敛）。
    private let minimumNormalizeAnimationDuration: TimeInterval = 0.18
    
    // MARK: - Lifecycle
    
    open override func prepareForReuse() {
        super.prepareForReuse()
        
        // 清空旧图像
        imageView.image = nil
        
        // 重置缩放与偏移
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        scrollView.contentOffset = .zero
        scrollView.contentInset = .zero
        
        // 重置缩放模式为初始状态（长边铺满）
        isShortEdgeFit = false
        isDismissInteracting = false
        pendingNormalizeAfterZoomAnimation = false
        
        // 重置布局状态，确保复用Cell时使用正确的尺寸信息
        lastBoundsSize = .zero
        
        // 恢复初始布局
        adjustImageViewFrame()
    }
    
    // MARK: - JXPhotoBrowserCellProtocol
    
    /// 若调用方提供的是 UIImageView，则可参与几何匹配 Zoom 动画
    open var transitionImageView: UIImageView? { imageView }

    open override func layoutSubviews() {
        super.layoutSubviews()
        
        let sizeChanged = lastBoundsSize != bounds.size
        if sizeChanged {
            lastBoundsSize = bounds.size
            // 旋转后重置缩放和缩放模式，避免旧尺寸导致的缩放计算错误
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
            isShortEdgeFit = false
            adjustImageViewFrame()
        } else if scrollView.zoomScale == scrollView.minimumZoomScale || imageView.frame.isEmpty {
            // 在未缩放状态下，根据图片比例调整 imageView.frame
            // 或者如果 imageView 大小为 0 (异常状态)，也强制调整
            adjustImageViewFrame()
        }
        // 任何时候（包括缩放时），都通过 inset 进行居中处理
        if !isDismissInteracting {
            centerImageIfNeeded()
        }
    }

    // MARK: - Layout Helper
    
    /// 获取有效的容器尺寸（兼容 ScrollView 尚未布局的情况）
    /// 优先使用 Cell 的 bounds，因为 scrollView.bounds 在旋转时可能更新滞后
    private var effectiveContentSize: CGSize {
        // 优先使用 Cell 的 bounds，确保在旋转时能获取到正确的尺寸
        let cellSize = bounds.size
        if cellSize.width > 0 && cellSize.height > 0 {
            return cellSize
        }
        // 如果 Cell bounds 无效，再尝试使用 scrollView.bounds
        let scrollSize = scrollView.bounds.size
        return (scrollSize.width > 0 && scrollSize.height > 0) ? scrollSize : cellSize
    }

    /// 根据图片实际尺寸，调整 imageView 的 frame（原点保持 (0,0)）
    /// 根据 isShortEdgeFit 状态选择缩放方式：
    /// - false: scaleAspectFit（长边铺满容器，短边等比例缩放，居中展示）
    /// - true: scaleAspectFill（短边铺满容器，长边等比例缩放）
    open func adjustImageViewFrame() {
        let containerSize = effectiveContentSize
        guard containerSize.width > 0, containerSize.height > 0 else { return }
        
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            // 图片未加载时，不再先铺满容器，避免先拉伸后收缩的闪动
            imageView.frame = .zero
            scrollView.contentSize = containerSize
            return
        }
        
        imageView.frame = imageFrame(
            for: image,
            in: containerSize,
            shortEdgeFit: isShortEdgeFit
        )
        scrollView.contentSize = imageView.frame.size
    }

    // MARK: - UIScrollViewDelegate
    open func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    open func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isDismissInteracting else { return }
        centerImageIfNeeded(alignMinimumOffset: false)
    }

    open func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        let isAtMinimumScale = abs(scale - scrollView.minimumZoomScale) < zoomEpsilon
        if pendingNormalizeAfterZoomAnimation || isAtMinimumScale {
            let reason = pendingNormalizeAfterZoomAnimation ? "doubleTapZoomAnimationEnd" : "pinchAtMinimum"
            pendingNormalizeAfterZoomAnimation = false
            normalizeToFitCenteredAtMinimum(animated: true, reason: reason)
        }
    }

    // MARK: - Helpers
    /// 在内容小于容器时居中展示（通过 contentInset 处理，避免 frame 偏移残留）
    open func centerImageIfNeeded(alignMinimumOffset: Bool = true) {
        // 优先使用 Cell 的 bounds，因为 scrollView.bounds 在旋转时可能更新滞后
        var containerSize = bounds.size
        if containerSize.width <= 0 || containerSize.height <= 0 {
            // 如果 Cell bounds 无效，再尝试使用 scrollView.bounds
            containerSize = scrollView.bounds.size
        }
        
        let imageSize = imageView.frame.size
        if containerSize.width <= 0 || containerSize.height <= 0 { return }
        if imageSize.width <= 0 || imageSize.height <= 0 { return }
        
        // 使用 contentInset 而非调整 frame，避免分页复用时的偏移遗留
        let horizontalInset = max(0, (containerSize.width - imageSize.width) * 0.5)
        let verticalInset = max(0, (containerSize.height - imageSize.height) * 0.5)
        
        let newInset = UIEdgeInsets(top: verticalInset, left: horizontalInset, bottom: verticalInset, right: horizontalInset)
        let insetChanged = scrollView.contentInset != newInset
        if insetChanged {
            scrollView.contentInset = newInset
        }
        
        if alignMinimumOffset && abs(scrollView.zoomScale - scrollView.minimumZoomScale) < zoomEpsilon {
            // 让内容视觉上居中，需要把 offset 调整到 inset 的负值
            let targetOffset = CGPoint(x: -horizontalInset, y: -verticalInset)
            if scrollView.contentOffset != targetOffset {
                scrollView.contentOffset = targetOffset
            }
        }
    }

    @objc open func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard !isDismissInteracting else { return }
        let currentScale = scrollView.zoomScale
        let isInitialScale = abs(currentScale - scrollView.minimumZoomScale) < zoomEpsilon
        
        // 获取点击位置用于计算放大时的目标偏移
        let tapInScrollView = gesture.location(in: scrollView)
        let tapInImageView = gesture.location(in: imageView)
        
        if isInitialScale {
            // 在初始缩放状态下，切换缩放模式（长边铺满 <-> 短边铺满）
            // 在 adjustImageViewFrame 之前保存当前偏移量，因为 adjustImageViewFrame 会临时改变
            // contentSize，UIKit 可能在此过程中钳制 contentOffset
            let originalOffset = scrollView.contentOffset
            isShortEdgeFit.toggle()
            // 先计算新的 frame
            let oldFrame = imageView.frame
            adjustImageViewFrame()
            let newFrame = imageView.frame
            let newContentSize = imageView.frame.size
            
            // 计算基于点击位置的目标 contentOffset（仅在放大到 aspectFill 时需要）
            var tapBasedOffset: CGPoint?
            if isShortEdgeFit, oldFrame.width > 0, oldFrame.height > 0 {
                // 点击位置在旧图片中的相对比例
                let scaleRatioX = newFrame.width / oldFrame.width
                let scaleRatioY = newFrame.height / oldFrame.height
                // 相同比例位置在新图片中的坐标
                let newTapInContent = CGPoint(
                    x: tapInImageView.x * scaleRatioX,
                    y: tapInImageView.y * scaleRatioY
                )
                let containerSize = bounds.size
                // 目标 offset：使新内容坐标点对齐到屏幕上的点击位置
                let rawOffsetX = newTapInContent.x - tapInScrollView.x
                let rawOffsetY = newTapInContent.y - tapInScrollView.y
                // 限制在有效范围内
                let adjustedInset = scrollView.adjustedContentInset
                let minOffsetX = -adjustedInset.left
                let minOffsetY = -adjustedInset.top
                let maxOffsetX = max(minOffsetX, newContentSize.width - containerSize.width + adjustedInset.right)
                let maxOffsetY = max(minOffsetY, newContentSize.height - containerSize.height + adjustedInset.bottom)
                tapBasedOffset = CGPoint(
                    x: min(max(minOffsetX, rawOffsetX), maxOffsetX),
                    y: min(max(minOffsetY, rawOffsetY), maxOffsetY)
                )
                #if DEBUG
                print(
                    "[JXPhotoBrowser.zoom] doubleTap.offsetClamp raw=(\(Int(rawOffsetX.rounded())),\(Int(rawOffsetY.rounded()))) clamped=(\(Int(tapBasedOffset!.x.rounded())),\(Int(tapBasedOffset!.y.rounded()))) rangeX=[\(Int(minOffsetX.rounded())),\(Int(maxOffsetX.rounded()))] rangeY=[\(Int(minOffsetY.rounded())),\(Int(maxOffsetY.rounded()))]"
                )
                #endif
            }
            
            // 恢复旧 frame 用于动画起点
            imageView.frame = oldFrame
            scrollView.contentSize = oldFrame.size
            centerImageIfNeeded()
            // 缩小时恢复原始 contentOffset 作为动画起点，
            // 避免 centerImageIfNeeded 或 adjustImageViewFrame 钳制导致的偏移闪跳
            if !isShortEdgeFit {
                scrollView.contentOffset = originalOffset
            }
            
            // 使用动画平滑切换
            UIView.animate(withDuration: 0.3, animations: {
                self.imageView.frame = newFrame
                self.scrollView.contentSize = newContentSize
                self.centerImageIfNeeded()
                
                // 在 centerImageIfNeeded 之后，覆盖 contentOffset 以定位到点击位置
                if let offset = tapBasedOffset {
                    self.scrollView.contentOffset = offset
                }
            })
        } else {
            // 在非初始缩放状态下，切换回初始状态（长边铺满模式）
            isShortEdgeFit = false
            let isAlreadyMinimum = abs(scrollView.zoomScale - scrollView.minimumZoomScale) < zoomEpsilon
            if isAlreadyMinimum {
                normalizeToFitCenteredAtMinimum(animated: true, reason: "doubleTapAtMinimum")
            } else {
                pendingNormalizeAfterZoomAnimation = true
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            }
        }
    }

    @objc open func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        browser?.dismissSelf()
    }
    
    // MARK: - Dismiss Interaction
    
    /// 下拉关闭交互状态变化时调用，子类可重写以响应下拉交互状态变化
    open func photoBrowserDismissInteractionDidChange(isInteracting: Bool) {
        if isDismissInteracting == isInteracting { return }
        isDismissInteracting = isInteracting
        if !isInteracting {
            normalizeToFitCenteredAtMinimum(animated: false, reason: "dismissInteractionEnd")
        }
    }

    /// 缩放结束后收敛到默认浏览状态：Fit + 居中，避免残留 Fill 偏移导致跳角问题。
    private func normalizeToFitCenteredAtMinimum(animated: Bool, reason: String) {
        isShortEdgeFit = false
        if abs(scrollView.zoomScale - scrollView.minimumZoomScale) >= zoomEpsilon {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        }
        let containerSize = effectiveContentSize
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            adjustImageViewFrame()
            centerImageIfNeeded(alignMinimumOffset: true)
            return
        }

        let targetFrame = imageFrame(for: image, in: containerSize, shortEdgeFit: false)
        let frameDelta =
            abs(imageView.frame.minX - targetFrame.minX) +
            abs(imageView.frame.minY - targetFrame.minY) +
            abs(imageView.frame.width - targetFrame.width) +
            abs(imageView.frame.height - targetFrame.height)
        let shouldAnimate = animated && frameDelta > 0.5

        let applyTargetState: () -> Void = {
            self.imageView.frame = targetFrame
            self.scrollView.contentSize = targetFrame.size
            self.centerImageIfNeeded(alignMinimumOffset: true)
        }

        if shouldAnimate {
            UIView.animate(
                withDuration: minimumNormalizeAnimationDuration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                applyTargetState()
            } completion: { _ in
                self.logNormalizeState(reason: reason, animated: true)
            }
        } else {
            applyTargetState()
            logNormalizeState(reason: reason, animated: false)
        }
    }

    /// 计算给定容器与缩放策略下的图片目标 frame（原点固定为 0,0）。
    private func imageFrame(for image: UIImage, in containerSize: CGSize, shortEdgeFit: Bool) -> CGRect {
        let widthScale = containerSize.width / image.size.width
        let heightScale = containerSize.height / image.size.height
        let scale = shortEdgeFit ? max(widthScale, heightScale) : min(widthScale, heightScale)
        return CGRect(
            x: 0,
            y: 0,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
    }

    private func logNormalizeState(reason: String, animated: Bool) {
        #if DEBUG
        print(
            "[JXPhotoBrowser.zoom] normalize.fitCentered reason=\(reason) animated=\(animated) scale=\(String(format: "%.3f", scrollView.zoomScale)) offset=(\(Int(scrollView.contentOffset.x.rounded())),\(Int(scrollView.contentOffset.y.rounded()))) inset=(\(Int(scrollView.contentInset.left.rounded())),\(Int(scrollView.contentInset.top.rounded())),\(Int(scrollView.contentInset.right.rounded())),\(Int(scrollView.contentInset.bottom.rounded())))"
        )
        #endif
    }
}
