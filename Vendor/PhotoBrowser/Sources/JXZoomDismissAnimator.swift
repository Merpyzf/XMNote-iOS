//
//  ZoomDismissAnimator.swift
//  JXPhotoBrowser
//

import UIKit

open class JXZoomDismissAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    open func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.25
    }
    
    open func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        let duration = transitionDuration(using: ctx)
        
        guard let fromVC = ctx.viewController(forKey: .from) as? JXPhotoBrowserViewController,
              let fromView = ctx.view(forKey: .from) else {
            ctx.completeTransition(false)
            return
        }
        
        if let toView = ctx.view(forKey: .to) {
            container.insertSubview(toView, belowSubview: fromView)
            toView.alpha = 1
            toView.layoutIfNeeded()
        }
        
        let pageIndex = fromVC.pageIndex
        // 前置条件不满足则直接降级为淡出
        guard let srcCell = fromVC.visibleCell(),
              let srcIV = srcCell.transitionImageView, srcIV.bounds.size != .zero,
              let thumbnailView = fromVC.delegate?.photoBrowser(fromVC, thumbnailViewAt: pageIndex) else {
            #if DEBUG
            print("[JXPhotoBrowser.dismiss] fallback=fade reason=missingSourceOrThumbnail pageIndex=\(pageIndex)")
            #endif
            animateFadeOut(view: fromView, duration: duration, ctx: ctx)
            return
        }
        
        // 以当前图片视图为蓝本构建临时缩放视图
        let zoomIV = UIImageView()
        zoomIV.image = srcIV.image
        zoomIV.contentMode = srcIV.contentMode
        zoomIV.clipsToBounds = srcIV.clipsToBounds
        zoomIV.layer.cornerRadius = srcIV.layer.cornerRadius
        zoomIV.backgroundColor = srcIV.backgroundColor
        
        // 起止几何
        let startFrame: CGRect
        if let presentationFrame = srcIV.layer.presentation()?.frame,
           let superview = srcIV.superview {
            startFrame = superview.convert(presentationFrame, to: container)
            #if DEBUG
            print("[JXPhotoBrowser.dismiss] startFrame.source=presentation")
            #endif
        } else {
            startFrame = srcIV.convert(srcIV.bounds, to: container)
            #if DEBUG
            print("[JXPhotoBrowser.dismiss] startFrame.source=model")
            #endif
        }
        let endFrame = thumbnailView.convert(thumbnailView.bounds, to: container)
        
        // 隐藏真实视图，避免重影
        srcIV.isHidden = true
        thumbnailView.isHidden = true
        
        zoomIV.frame = startFrame
        container.addSubview(zoomIV)
        
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: {
                zoomIV.frame = endFrame
                fromView.alpha = 0
            }
        ) { _ in
            let wasCancelled = ctx.transitionWasCancelled
            thumbnailView.isHidden = false
            if !wasCancelled {
                fromVC.delegate?.photoBrowser(fromVC, setThumbnailHidden: false, at: pageIndex)
            }
            zoomIV.removeFromSuperview()
            if wasCancelled {
                srcIV.isHidden = false
                fromView.alpha = 1
            } else {
                fromView.removeFromSuperview()
            }
            ctx.completeTransition(!wasCancelled)
        }
    }
    
    // MARK: - Helpers
    
    /// 降级为淡出动画（不缩放，可覆写）
    open func animateFadeOut(view: UIView, duration: TimeInterval, ctx: UIViewControllerContextTransitioning) {
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            view.alpha = 0
        } completion: { _ in
            let wasCancelled = ctx.transitionWasCancelled
            if wasCancelled {
                view.alpha = 1
                ctx.completeTransition(false)
            } else {
                view.removeFromSuperview()
                ctx.completeTransition(true)
            }
        }
    }
}
