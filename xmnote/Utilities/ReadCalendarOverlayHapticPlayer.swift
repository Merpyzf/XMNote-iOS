/**
 * [INPUT]: 依赖 CoreHaptics 框架与 UIKit 触感降级
 * [OUTPUT]: 对外提供 ReadCalendarOverlayHapticPlayer（封面弹窗全生命周期触感编排器）
 * [POS]: Utilities 模块的领域触感工具，为阅读日历封面弹窗提供持续性 CoreHaptics 曲线触感
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreHaptics
import UIKit

/// 封面弹窗触感播放器，基于 CoreHaptics 时间轴曲线实现展开/收起的持续性震动体验。
///
/// 生命周期与弹窗绑定：
/// - `onAppear` 时构造并调用 `playOpenHaptic()`
/// - 展开/收起时分别调用 `playExpandHaptic()` / `playCollapseHaptic()`
/// - `onDisappear` 时调用 `shutdown()` 释放引擎
///
/// 降级策略：设备不支持 CoreHaptics 时回退到 UIImpactFeedbackGenerator 单次冲击；
/// `accessibilityReduceMotion` 时仅保留极轻 transient 确认；触感关闭时全部跳过。
@MainActor
/// 阅读日历封面浮层触感播放器，统一管理展开、收起与降级路径。
final class ReadCalendarOverlayHapticPlayer {

    private var engine: CHHapticEngine?
    private var activePlayer: CHHapticAdvancedPatternPlayer?
    private let supportsHaptics: Bool

    init() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak engine] in
                try? engine?.start()
            }
            try engine.start()
            self.engine = engine
        } catch {
            engine = nil
        }
    }

    // MARK: - Public

    /// 弹窗打开：120ms 双击微序列（软着陆 + 回弹余韵）。
    func playOpenHaptic(isHapticsEnabled: Bool, reduceMotion: Bool) {
        guard isHapticsEnabled else { return }
        guard supportsHaptics, engine != nil else {
            fallbackImpact(style: .soft, intensity: 0.82)
            return
        }
        if reduceMotion {
            playMinimalConfirmation()
            return
        }
        let events: [CHHapticEvent] = [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35),
                ],
                relativeTime: 0
            ),
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.18),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
                ],
                relativeTime: 0.05
            ),
        ]
        playPattern(events: events)
    }

    /// 展开（stacked→grid）：380ms「书页翻飞」渐入渐出持续震动。
    func playExpandHaptic(isHapticsEnabled: Bool, reduceMotion: Bool) {
        guard isHapticsEnabled else { return }
        guard supportsHaptics, engine != nil else {
            fallbackImpact(style: .light, intensity: 0.62)
            return
        }
        if reduceMotion {
            playMinimalConfirmation()
            return
        }
        let transient = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
            ],
            relativeTime: 0
        )
        let continuous = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.18),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.50),
            ],
            relativeTime: 0,
            duration: 0.38
        )
        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.18),
                .init(relativeTime: 0.06, value: 0.38),
                .init(relativeTime: 0.14, value: 0.52),
                .init(relativeTime: 0.24, value: 0.34),
                .init(relativeTime: 0.34, value: 0.16),
                .init(relativeTime: 0.38, value: 0.0),
            ],
            relativeTime: 0
        )
        let sharpnessCurve = CHHapticParameterCurve(
            parameterID: .hapticSharpnessControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.50),
                .init(relativeTime: 0.14, value: 0.35),
                .init(relativeTime: 0.34, value: 0.20),
            ],
            relativeTime: 0
        )
        playPattern(events: [transient, continuous], parameterCurves: [intensityCurve, sharpnessCurve])
    }

    /// 收起（grid→stacked）：280ms「合拢」前重后轻持续震动。
    func playCollapseHaptic(isHapticsEnabled: Bool, reduceMotion: Bool) {
        guard isHapticsEnabled else { return }
        guard supportsHaptics, engine != nil else {
            fallbackImpact(style: .medium, intensity: 0.72)
            return
        }
        if reduceMotion {
            playMinimalConfirmation()
            return
        }
        let transient = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
            ],
            relativeTime: 0
        )
        let continuous = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.46),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.60),
            ],
            relativeTime: 0,
            duration: 0.28
        )
        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.46),
                .init(relativeTime: 0.04, value: 0.56),
                .init(relativeTime: 0.10, value: 0.40),
                .init(relativeTime: 0.18, value: 0.20),
                .init(relativeTime: 0.28, value: 0.0),
            ],
            relativeTime: 0
        )
        let sharpnessCurve = CHHapticParameterCurve(
            parameterID: .hapticSharpnessControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.60),
                .init(relativeTime: 0.10, value: 0.45),
                .init(relativeTime: 0.28, value: 0.30),
            ],
            relativeTime: 0
        )
        playPattern(events: [transient, continuous], parameterCurves: [intensityCurve, sharpnessCurve])
    }

    /// 中断当前触感播放。
    func stop() {
        try? activePlayer?.stop(atTime: CHHapticTimeImmediate)
        activePlayer = nil
    }

    /// 释放引擎资源，弹窗消失时调用。
    func shutdown() {
        stop()
        engine?.stop(completionHandler: { _ in })
        engine = nil
    }

    // MARK: - Private

    /// 封装playPattern对应的业务步骤，确保调用方可以稳定复用该能力。
    private func playPattern(
        events: [CHHapticEvent],
        parameterCurves: [CHHapticParameterCurve] = []
    ) {
        guard let engine else { return }
        do {
            stop()
            let pattern = try CHHapticPattern(events: events, parameterCurves: parameterCurves)
            let player = try engine.makeAdvancedPlayer(with: pattern)
            activePlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // 静默降级，不阻断 UI
        }
    }

    /// 封装playMinimalConfirmation对应的业务步骤，确保调用方可以稳定复用该能力。
    private func playMinimalConfirmation() {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.15),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
            ],
            relativeTime: 0
        )
        playPattern(events: [event])
    }

    /// 封装fallbackImpact对应的业务步骤，确保调用方可以稳定复用该能力。
    private func fallbackImpact(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }
}
