import UIKit

/// 自定义 NSLayoutManager，绘制 bullet 圆点和 blockquote 色条
/// 对标 KnifeBulletSpan.drawLeadingMargin + KnifeQuoteSpan.drawLeadingMargin
final class RichTextLayoutManager: NSLayoutManager {

    /// Bullet 圆点半径（pt）
    var bulletRadius: CGFloat = 3
    /// Bullet 圆点颜色
    var bulletColor: UIColor = .label

    /// Quote 色条宽度（pt）
    var quoteStripeWidth: CGFloat = 2
    /// Quote 色条颜色
    var quoteColor: UIColor = .systemGreen

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let textStorage = textStorage, let context = UIGraphicsGetCurrentContext() else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        // 遍历段落级属性
        textStorage.enumerateAttributes(in: charRange, options: []) { attrs, range, _ in
            let isBullet = attrs[.bulletList] != nil
            let isQuote = attrs[.blockquote] != nil

            guard isBullet || isQuote else { return }

            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)

            self.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, usedRect, container, lineGlyphRange, _ in
                // 只在段落首行绘制 bullet 圆点
                let lineCharRange = self.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)

                if isBullet {
                    // 检查是否为该段落属性的起始行
                    if lineCharRange.location == range.location {
                        self.drawBullet(in: context, lineRect: lineRect, origin: origin, containerInset: container.lineFragmentPadding)
                    }
                }

                if isQuote {
                    self.drawQuoteStripe(in: context, lineRect: lineRect, origin: origin, containerInset: container.lineFragmentPadding)
                }
            }
        }
    }

    // MARK: - Bullet 圆点绘制

    /// 对标 KnifeBulletSpan.drawLeadingMargin:
    /// c.drawCircle(x + dir * bulletRadius, (top + bottom) / 2.0f, bulletRadius, p)
    private func drawBullet(in context: CGContext, lineRect: CGRect, origin: CGPoint, containerInset: CGFloat) {
        let x = origin.x + containerInset + bulletRadius
        let y = origin.y + lineRect.midY
        let rect = CGRect(x: x - bulletRadius, y: y - bulletRadius, width: bulletRadius * 2, height: bulletRadius * 2)

        context.setFillColor(bulletColor.cgColor)
        context.fillEllipse(in: rect)
    }

    // MARK: - Quote 色条绘制

    /// 对标 KnifeQuoteSpan.drawLeadingMargin:
    /// c.drawRect(x, top, x + dir * quoteGapWidth, bottom, p)
    private func drawQuoteStripe(in context: CGContext, lineRect: CGRect, origin: CGPoint, containerInset: CGFloat) {
        let x = origin.x + containerInset
        let top = origin.y + lineRect.minY
        let bottom = origin.y + lineRect.maxY
        let rect = CGRect(x: x, y: top, width: quoteStripeWidth, height: bottom - top)

        context.setFillColor(quoteColor.cgColor)
        context.fill(rect)
    }
}
