/**
 * [INPUT]: 依赖语义颜色、InteractionMetrics、SwiftUI/UIKit 最小命中基础设施、LoadingFeedbackKit 与 XMJXGalleryItem 的公开行为契约
 * [OUTPUT]: 验证动态色、双 UI 框架最小触控目标、图片无障碍名称，以及加载门闩的即时、延迟、取消与最短驻留行为
 * [POS]: xmnoteTests 的设计系统基础设施回归测试，保护颜色、交互尺寸、无障碍输入与加载反馈稳定边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import Testing
import UIKit
@testable import xmnote

@MainActor
struct DesignSystemInfrastructureTests {
    @Test func adaptiveColorsResolveAppearanceAndAccessibilityContrast() {
        let swiftUIColor = Color.xmAdaptive(
            light: Color.xmHex(0x112233),
            dark: Color.xmHex(0x445566),
            highContrastLight: Color.xmHex(0x778899),
            highContrastDark: Color.xmHex(0xAABBCC)
        )
        let uiColor = UIColor.xmAdaptive(
            lightHex: 0x112233,
            darkHex: 0x445566,
            highContrastLightHex: 0x778899,
            highContrastDarkHex: 0xAABBCC
        )

        assertColor(swiftUIColor, resolvesTo: 0x112233, style: .light, contrast: .normal)
        assertColor(swiftUIColor, resolvesTo: 0x445566, style: .dark, contrast: .normal)
        assertColor(swiftUIColor, resolvesTo: 0x778899, style: .light, contrast: .high)
        assertColor(swiftUIColor, resolvesTo: 0xAABBCC, style: .dark, contrast: .high)
        assertColor(uiColor, resolvesTo: 0x112233, style: .light, contrast: .normal)
        assertColor(uiColor, resolvesTo: 0x445566, style: .dark, contrast: .normal)
        assertColor(uiColor, resolvesTo: 0x778899, style: .light, contrast: .high)
        assertColor(uiColor, resolvesTo: 0xAABBCC, style: .dark, contrast: .high)
    }

    @Test func highContrastPrimaryActionUsesLegiblePairedColors() {
        let lightTraits = traits(style: .light, contrast: .high)
        let darkTraits = traits(style: .dark, contrast: .high)
        let lightFill = resolved(Color.primaryActionFill, traits: lightTraits)
        let lightForeground = resolved(Color.primaryActionForeground, traits: lightTraits)
        let darkFill = resolved(Color.primaryActionFill, traits: darkTraits)
        let darkForeground = resolved(Color.primaryActionForeground, traits: darkTraits)

        #expect(contrastRatio(lightFill, lightForeground) >= 4.5)
        #expect(contrastRatio(darkFill, darkForeground) >= 4.5)
    }

    @Test func minimumTouchTargetKeepsPlatformInteractionContract() {
        #expect(InteractionMetrics.minimumTouchTarget == 44)
    }

    @Test func UIKitMinimumHitTargetExpandsInteractionWithoutChangingVisualBounds() {
        let button = XMMinimumHitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 32))
        let originalBounds = button.bounds

        #expect(button.expandedHitBounds.size == CGSize(width: 44, height: 44))
        #expect(button.bounds == originalBounds)
        #expect(button.point(inside: CGPoint(x: -9, y: 16), with: nil))
        #expect(!button.point(inside: CGPoint(x: -11, y: 16), with: nil))

        button.hitTargetAnchor = .topTrailing
        #expect(button.expandedHitBounds == CGRect(x: -20, y: 0, width: 44, height: 44))
        #expect(button.bounds == originalBounds)

        button.isEnabled = false
        #expect(!button.point(inside: CGPoint(x: 12, y: 16), with: nil))
    }

    @Test func SwiftUIMinimumHitTargetExpandsShapeWithoutChangingVisualRect() {
        let visualRect = CGRect(x: 0, y: 0, width: 24, height: 32)
        let centeredShape = XMMinimumHitTargetShape()
        let topShape = XMMinimumHitTargetShape(anchor: .top)
        let trailingShape = XMMinimumHitTargetShape(anchor: .topTrailing)
        let rightToLeftTrailingShape = XMMinimumHitTargetShape(
            anchor: .topTrailing,
            layoutDirection: .rightToLeft
        )

        #expect(centeredShape.expandedRect(in: visualRect) == CGRect(x: -10, y: -6, width: 44, height: 44))
        #expect(topShape.expandedRect(in: visualRect) == CGRect(x: -10, y: 0, width: 44, height: 44))
        #expect(trailingShape.expandedRect(in: visualRect) == CGRect(x: -20, y: 0, width: 44, height: 44))
        #expect(rightToLeftTrailingShape.expandedRect(in: visualRect) == CGRect(x: 0, y: 0, width: 44, height: 44))
        #expect(visualRect == CGRect(x: 0, y: 0, width: 24, height: 32))
    }

    @Test func loadingPoliciesKeepReadAndWriteFeedbackRhythm() {
        #expect(LoadingPolicy.readDefault.delay == .milliseconds(150))
        #expect(LoadingPolicy.readDefault.minimumVisible == .milliseconds(200))
        #expect(LoadingPolicy.writeImmediate.delay == .zero)
        #expect(LoadingPolicy.writeImmediate.minimumVisible == .zero)
    }

    @Test func galleryItemPreservesOptionalAccessibilityName() {
        let unlabeled = XMJXGalleryItem(id: "1", thumbnailURL: "thumb", originalURL: "original")
        let labeled = XMJXGalleryItem(
            id: "2",
            thumbnailURL: "thumb",
            originalURL: "original",
            accessibilityLabel: "书摘配图"
        )

        #expect(unlabeled.accessibilityLabel == nil)
        #expect(labeled.accessibilityLabel == "书摘配图")
    }

    @Test func writeIntentShowsImmediatelyAndCanHideImmediately() {
        let gate = LoadingGate()

        gate.update(intent: .write)
        #expect(gate.isVisible)

        gate.hideImmediately()
        #expect(!gate.isVisible)
    }

    @Test func cancellingDelayedReadPreventsLateLoadingFlash() async throws {
        let gate = LoadingGate()
        let policy = LoadingPolicy(
            delay: .milliseconds(120),
            minimumVisible: .zero,
            showAnimation: .linear(duration: 0),
            hideAnimation: .linear(duration: 0)
        )

        gate.update(intent: .read, policy: policy)
        #expect(!gate.isVisible)

        gate.update(intent: .none, policy: policy)
        try await Task.sleep(for: .milliseconds(180))

        #expect(!gate.isVisible)
    }

    @Test func visibleReadHonorsMinimumResidenceBeforeHiding() async throws {
        let gate = LoadingGate()
        let policy = LoadingPolicy(
            delay: .zero,
            minimumVisible: .milliseconds(100),
            showAnimation: .linear(duration: 0),
            hideAnimation: .linear(duration: 0)
        )

        gate.update(intent: .read, policy: policy)
        #expect(gate.isVisible)

        gate.update(intent: .none, policy: policy)
        #expect(gate.isVisible)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while gate.isVisible, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!gate.isVisible)
    }

    private func assertColor(
        _ color: Color,
        resolvesTo hex: UInt,
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast
    ) {
        let actual = resolved(color, traits: traits(style: style, contrast: contrast))
        assertColorComponents(actual, equalTo: UIColor.xmHex(hex))
    }

    private func assertColor(
        _ color: UIColor,
        resolvesTo hex: UInt,
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast
    ) {
        let actual = color.resolvedColor(with: traits(style: style, contrast: contrast))
        assertColorComponents(actual, equalTo: UIColor.xmHex(hex))
    }

    private func resolved(_ color: Color, traits: UITraitCollection) -> UIColor {
        UIColor.xmResolved(color).resolvedColor(with: traits)
    }

    private func traits(
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast
    ) -> UITraitCollection {
        UITraitCollection(mutations: { mutableTraits in
            mutableTraits.userInterfaceStyle = style
            mutableTraits.accessibilityContrast = contrast
        })
    }

    private func assertColorComponents(_ actual: UIColor, equalTo expected: UIColor) {
        var actualRed: CGFloat = 0
        var actualGreen: CGFloat = 0
        var actualBlue: CGFloat = 0
        var actualAlpha: CGFloat = 0
        var expectedRed: CGFloat = 0
        var expectedGreen: CGFloat = 0
        var expectedBlue: CGFloat = 0
        var expectedAlpha: CGFloat = 0

        #expect(actual.getRed(
            &actualRed,
            green: &actualGreen,
            blue: &actualBlue,
            alpha: &actualAlpha
        ))
        #expect(expected.getRed(
            &expectedRed,
            green: &expectedGreen,
            blue: &expectedBlue,
            alpha: &expectedAlpha
        ))
        #expect(abs(actualRed - expectedRed) < 0.000_1)
        #expect(abs(actualGreen - expectedGreen) < 0.000_1)
        #expect(abs(actualBlue - expectedBlue) < 0.000_1)
        #expect(abs(actualAlpha - expectedAlpha) < 0.000_1)
    }

    private func contrastRatio(_ lhs: UIColor, _ rhs: UIColor) -> Double {
        let brighter = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let darker = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (brighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linearized(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }
}
