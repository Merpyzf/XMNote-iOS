/**
 * [INPUT]: 依赖 Core Text 准备线程内排版及已解析的不可变富文本
 * [OUTPUT]: 提供书摘画布、瀑布流与转场共用的不可变文字绘制指令
 * [POS]: NoteReviewCanvas 内部渲染内核；不持有业务会话或跨线程排版对象
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit
import CoreText

/// 在主线程捕获项目富文本属性身份，绘制内核不读取 actor 隔离的编辑器符号。
nonisolated struct NoteReviewCanvasTextAttributes: Sendable {
    let quote: NSAttributedString.Key
    let bullet: NSAttributedString.Key
    let italic: NSAttributedString.Key

    @MainActor static var project: Self {
        Self(quote: .blockquote, bullet: .bulletList, italic: .obliqueItalic)
    }
}

/// 准备任务输出的轻量行信息；供端点一致性和换行识别使用，不保留 CTLine。
nonisolated struct NoteReviewCanvasLineMetric: Sendable {
    let range: NSRange
    let origin: CGPoint
    let width: CGFloat
}

/// 一次准备后可重复绘制的字形指令。CTFont 可跨线程共享，CTRun 不可。
/// Core Text 文档允许字体跨线程共享，但 SDK 尚未声明 Sendable；只对不可变字体做窄桥接。
nonisolated struct NoteReviewCanvasFont: @unchecked Sendable {
    fileprivate let value: CTFont
}

/// 字形和坐标均为值数组，后续新增字段仍须满足编译器的 Sendable 检查。
nonisolated struct NoteReviewCanvasGlyphRun: Sendable {
    let font: NoteReviewCanvasFont
    let glyphs: [CGGlyph]
    let positions: [CGPoint]
    let color: CGColor
    let matrix: CGAffineTransform

    /// 调用方独占 CGContext；绘制不访问视图、富文本或排版器。
    func draw(in context: CGContext) {
        context.saveGState()
        context.setFillColor(color)
        context.textMatrix = matrix
        context.textPosition = .zero
        glyphs.withUnsafeBufferPointer { glyphs in
            positions.withUnsafeBufferPointer { positions in
                guard let g = glyphs.baseAddress, let p = positions.baseAddress else { return }
                CTFontDrawGlyphs(font.value, g, p, glyphs.count, context)
            }
        }
        context.restoreGState()
    }
}

/// 不可变文本端点。所有 CTFrame / CTLine / CTRun 都在 init 内创建并释放。
/// 普通字形使用向量指令，特殊 Core Text 绘制效果使用准备阶段局部栅格。
nonisolated struct NoteReviewCanvasTextLayout: Sendable {
    let size: CGSize
    let metrics: [NoteReviewCanvasLineMetric]
    let runs: [NoteReviewCanvasGlyphRun]
    let decorations: [NoteReviewCanvasTextDecoration]
    let specialImage: CGImage?
    let visibleRange: NSRange
    let cost: Int

    /// 必须在准备队列调用；独立 Framesetter 不与其他任务共享。取消由外层在文本块之间检查。
    init(text: NSAttributedString, size: CGSize, attributes keys: NoteReviewCanvasTextAttributes, rasterScale: CGFloat = 3) {
        self.size = size
        guard text.length > 0, size.width > 0, size.height > 0 else {
            metrics = []; runs = []; decorations = []; specialImage = nil
            visibleRange = NSRange(location: 0, length: 0); cost = 0
            return
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        if !lines.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
        let visible = CTFrameGetVisibleStringRange(frame)
        visibleRange = NSRange(location: visible.location, length: visible.length)
        metrics = lines.enumerated().map { index, line in
            let range = CTLineGetStringRange(line)
            return NoteReviewCanvasLineMetric(range: NSRange(location: range.location, length: range.length),
                origin: origins[index], width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        decorations = NoteReviewCanvasTextDecoration.make(lines: lines, origins: origins, text: text, height: size.height, keys: keys)
        var instructions: [NoteReviewCanvasGlyphRun] = []
        var needsRaster = false
        for (index, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = attributes[kCTFontAttributeName] as! CTFont
                let matrix = CTRunGetTextMatrix(run)
                // Preserve color glyphs, synthetic styles, underline and stroke exactly through CTLineDraw.
                if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
                    || !matrix.isIdentity
                    || attributes[NSAttributedString.Key.underlineStyle] != nil
                    || attributes[NSAttributedString.Key.obliqueness] != nil
                    || attributes[keys.italic] != nil
                    || attributes[NSAttributedString.Key.strokeWidth] != nil {
                    needsRaster = true
                }
                var glyphs = Array(repeating: CGGlyph(), count: count)
                var positions = Array(repeating: CGPoint.zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                positions = positions.map { CGPoint(x: $0.x + origins[index].x, y: $0.y + origins[index].y) }
                let value = attributes[kCTForegroundColorAttributeName] ?? attributes[NSAttributedString.Key.foregroundColor]
                let color: CGColor
                if let uiColor = value as? UIColor { color = uiColor.cgColor }
                else if let value, CFGetTypeID(value as CFTypeRef) == CGColor.typeID { color = value as! CGColor }
                else { color = CGColor(gray: 0, alpha: 1) }
                instructions.append(NoteReviewCanvasGlyphRun(font: NoteReviewCanvasFont(value: font), glyphs: glyphs, positions: positions,
                    color: color, matrix: matrix))
            }
        }
        if needsRaster, let image = Self.raster(lines: lines, origins: origins, size: size, scale: rasterScale) {
            specialImage = image
            runs = []
            cost = image.bytesPerRow * image.height + decorations.count * 96 + metrics.count * 64
        } else {
            specialImage = nil
            runs = instructions
            cost = instructions.reduce(0) { $0 + $1.glyphs.count * (MemoryLayout<CGGlyph>.stride + MemoryLayout<CGPoint>.stride) + 256 }
                + decorations.count * 96 + metrics.count * 64
        }
    }

    /// 调用方独占绘制上下文；坐标为左上原点，所有输入已在准备阶段固化。
    func draw(in context: CGContext) {
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: size))
        for item in decorations where !item.isForeground { item.draw(in: context) }
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        if let specialImage {
            context.draw(specialImage, in: CGRect(origin: .zero, size: size))
        } else {
            for run in runs { run.draw(in: context) }
        }
        context.restoreGState()
        for item in decorations where item.isForeground { item.draw(in: context) }
        context.restoreGState()
    }

    /// 特殊效果在所属任务中完成 Core Text 绘制；跨线程仅传递不可变 CGImage。
    private static func raster(lines: [CTLine], origins: [CGPoint], size: CGSize, scale: CGFloat) -> CGImage? {
        let scale = max(1, min(4, scale))
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        context.textMatrix = .identity
        for (index, line) in lines.enumerated() {
            context.textPosition = origins[index]
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
}

/// 解析器附加的引用、列表、高亮与删除线绘制数据。
nonisolated struct NoteReviewCanvasTextDecoration: Sendable {
    let rect: CGRect
    let color: CGColor
    var isBullet = false
    var isForeground = false

    /// 只在拥有行对象的准备任务中提取装饰；结果不持有任何 Core Text 布局对象。
    static func make(lines: [CTLine], origins: [CGPoint], text: NSAttributedString,
                     height: CGFloat, keys: NoteReviewCanvasTextAttributes) -> [NoteReviewCanvasTextDecoration] {
        var result: [NoteReviewCanvasTextDecoration] = []
        let string = text.string as NSString
        for (index, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            guard lineRange.location < text.length else { continue }
            let baseline = height - origins[index].y
            var lineAscent: CGFloat = 0
            var lineDescent: CGFloat = 0
            CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
            let attrs = text.attributes(at: lineRange.location, effectiveRange: nil)
            if attrs[keys.quote] != nil {
                result.append(Self(rect: CGRect(x: 0, y: baseline - lineAscent,
                    width: 2, height: lineAscent + lineDescent),
                    color: (attrs[NSAttributedString.Key("prototypeQuoteColor")] as? UIColor ?? .secondaryLabel).cgColor))
            }
            if attrs[keys.bullet] != nil,
               string.paragraphRange(for: NSRange(location: lineRange.location, length: 0)).location == lineRange.location {
                let color = (attrs[.foregroundColor] as? UIColor ?? .label).cgColor
                result.append(Self(rect: CGRect(x: 0, y: baseline - lineAscent / 2 - 3,
                                                width: 6, height: 6), color: color, isBullet: true))
            }
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
                var position = CGPoint.zero
                if CTRunGetGlyphCount(run) > 0 { CTRunGetPositions(run, CFRange(location: 0, length: 1), &position) }
                let x = origins[index].x + position.x
                if let color = attributes[.backgroundColor] as? UIColor {
                    result.append(Self(rect: CGRect(x: x, y: baseline - ascent, width: width,
                                                     height: ascent + descent), color: color.cgColor))
                }
                if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
                    let color = (attributes[.foregroundColor] as? UIColor ?? .label).cgColor
                    result.append(Self(rect: CGRect(x: x, y: baseline - ascent * 0.35,
                        width: width, height: 0.8), color: color, isForeground: true))
                }
            }
        }
        return result
    }

    /// 使用已解析的颜色和区域绘制，不访问动态 trait 或文本。
    func draw(in context: CGContext) {
        context.setFillColor(color)
        if isBullet { context.fillEllipse(in: rect) } else { context.fill(rect) }
    }
}
