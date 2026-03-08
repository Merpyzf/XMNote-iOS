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
    
    /// 双击手势：Fit 态下放大到 doubleTapZoomScale（以点击位置为中心），放大态下回到 Fit
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
    
    /// 下拉关闭交互进行中时，锁定内部缩放/布局校正，避免与外层手势产生竞态。
    private(set) var isDismissInteracting: Bool = false

    /// 缩放收敛判定容差。
    private let zoomEpsilon: CGFloat = 0.01
    
    // MARK: - Lifecycle
    
    open override func prepareForReuse() {
        super.prepareForReuse()
        
        // 清空旧图像
        imageView.image = nil
        
        // 重置缩放与偏移
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        scrollView.contentOffset = .zero
        scrollView.contentInset = .zero
        
        // 重置缩放模式为初始状态
        isDismissInteracting = false
        
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
            // 旋转后重置缩放，避免旧尺寸导致的缩放计算错误
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
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

    /// 始终以 Fit（长边铺满）计算 imageView 的 frame，作为 zoomScale = 1.0 的基准态。
    open func adjustImageViewFrame() {
        let containerSize = effectiveContentSize
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            imageView.frame = .zero
            scrollView.contentSize = containerSize
            return
        }

        let fitScale = min(containerSize.width / image.size.width,
                           containerSize.height / image.size.height)
        let fitSize = CGSize(width: image.size.width * fitScale,
                             height: image.size.height * fitScale)
        imageView.frame = CGRect(origin: .zero, size: fitSize)
        scrollView.contentSize = fitSize
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
        if abs(scale - scrollView.minimumZoomScale) < zoomEpsilon {
            centerImageIfNeeded(alignMinimumOffset: true)
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

    /// 双击放大的目标 zoomScale：取 fillScale 与 2.0 的较大值，确保任何比例图片都有明显放大。
    private var doubleTapZoomScale: CGFloat {
        let containerSize = effectiveContentSize
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return 2.0 }
        let wScale = containerSize.width / image.size.width
        let hScale = containerSize.height / image.size.height
        let fillScale = max(wScale, hScale) / min(wScale, hScale)
        return max(fillScale, 2.0)
    }

    /// 计算以指定点为中心、对应目标缩放倍率的可见区域矩形（content 坐标系）。
    private func zoomRect(for scale: CGFloat, center: CGPoint) -> CGRect {
        let size = CGSize(width: scrollView.bounds.width / scale,
                          height: scrollView.bounds.height / scale)
        return CGRect(x: center.x - size.width / 2,
                      y: center.y - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    @objc open func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard !isDismissInteracting else { return }
        let isAtMinimum = abs(scrollView.zoomScale - scrollView.minimumZoomScale) < zoomEpsilon

        if isAtMinimum {
            let tapPoint = gesture.location(in: imageView)
            let targetScale = doubleTapZoomScale
            scrollView.zoom(to: zoomRect(for: targetScale, center: tapPoint), animated: true)
        } else {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
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

    /// 缩放结束后收敛到默认浏览状态：Fit + 居中。
    private func normalizeToFitCenteredAtMinimum(animated: Bool, reason: String) {
        if abs(scrollView.zoomScale - scrollView.minimumZoomScale) >= zoomEpsilon {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        }
        adjustImageViewFrame()
        centerImageIfNeeded(alignMinimumOffset: true)
        logNormalizeState(reason: reason, animated: animated)
    }

    private func logNormalizeState(reason: String, animated: Bool) {
        #if DEBUG
        print(
            "[JXPhotoBrowser.zoom] normalize.fitCentered reason=\(reason) animated=\(animated) scale=\(String(format: "%.3f", scrollView.zoomScale)) offset=(\(Int(scrollView.contentOffset.x.rounded())),\(Int(scrollView.contentOffset.y.rounded()))) inset=(\(Int(scrollView.contentInset.left.rounded())),\(Int(scrollView.contentInset.top.rounded())),\(Int(scrollView.contentInset.right.rounded())),\(Int(scrollView.contentInset.bottom.rounded())))"
        )
        #endif
    }
}
