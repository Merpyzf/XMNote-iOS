/**
 * [INPUT]: 依赖 SwiftUI 动画与几何类型，接收过渡阶段、进度与时长配置
 * [OUTPUT]: 对外提供 ReadCalendarCoverTransitionSpec / ReadCalendarCoverTransitionRuntime（封面弹层统一动画时序模型）
 * [POS]: ReadCalendar 页面私有动画基础设施，用于统一“日格书堆 -> 弹层舞台”过渡节奏
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// ReadCalendarCoverTransitionPhase 描述封面弹层过渡生命周期阶段。
enum ReadCalendarCoverTransitionPhase: Hashable {
    case idle
    case entering
    case steady
    case exiting
}

/// ReadCalendarCoverTransitionChannels 描述当前帧中四条视觉通道的强度。
struct ReadCalendarCoverTransitionChannels: Hashable {
    let backdropOpacity: CGFloat
    let deckOpacity: CGFloat
    let ghostOpacity: CGFloat
    let chromeOpacity: CGFloat
}

/// ReadCalendarCoverTransitionSpec 定义封面弹层过渡时长、位移与缩放参数。
struct ReadCalendarCoverTransitionSpec: Hashable {
    let openDuration: Double
    let closeDuration: Double

    let entryBackdropDuration: Double
    let entryDeckDelay: Double
    let entryDeckDuration: Double
    let entryGhostFadeDelay: Double
    let entryGhostFadeDuration: Double
    let entryChromeDelay: Double
    let entryChromeDuration: Double

    let exitBackdropDuration: Double
    let exitDeckFadeDuration: Double
    let exitGhostFadeInDelay: Double
    let exitGhostFadeInDuration: Double
    let exitGhostFadeOutDelay: Double
    let exitGhostFadeOutDuration: Double

    let panelEntryOffsetY: CGFloat
    let panelExitOffsetY: CGFloat
    let panelEntryScaleFrom: CGFloat
    let panelExitScaleTo: CGFloat

    /// immersiveElegant 提供沉浸优雅档时长配置。
    static let immersiveElegant = ReadCalendarCoverTransitionSpec(
        openDuration: 0.34,
        closeDuration: 0.30,
        entryBackdropDuration: 0.19,
        entryDeckDelay: 0.06,
        entryDeckDuration: 0.14,
        entryGhostFadeDelay: 0.08,
        entryGhostFadeDuration: 0.13,
        entryChromeDelay: 0.12,
        entryChromeDuration: 0.11,
        exitBackdropDuration: 0.24,
        exitDeckFadeDuration: 0.22,
        exitGhostFadeInDelay: 0.03,
        exitGhostFadeInDuration: 0.10,
        exitGhostFadeOutDelay: 0.19,
        exitGhostFadeOutDuration: 0.10,
        panelEntryOffsetY: 34,
        panelExitOffsetY: 20,
        panelEntryScaleFrom: 0.97,
        panelExitScaleTo: 0.93
    )

    /// reduceMotion 提供减少动态效果场景下的降级配置。
    static let reduceMotion = ReadCalendarCoverTransitionSpec(
        openDuration: 0.18,
        closeDuration: 0.16,
        entryBackdropDuration: 0.16,
        entryDeckDelay: 0,
        entryDeckDuration: 0.18,
        entryGhostFadeDelay: 0,
        entryGhostFadeDuration: 0.14,
        entryChromeDelay: 0.04,
        entryChromeDuration: 0.14,
        exitBackdropDuration: 0.16,
        exitDeckFadeDuration: 0.14,
        exitGhostFadeInDelay: 0,
        exitGhostFadeInDuration: 0.06,
        exitGhostFadeOutDelay: 0.08,
        exitGhostFadeOutDuration: 0.08,
        panelEntryOffsetY: 0,
        panelExitOffsetY: 0,
        panelEntryScaleFrom: 1,
        panelExitScaleTo: 1
    )
}

/// ReadCalendarCoverTransitionRuntime 负责将阶段与进度映射为视觉通道值。
enum ReadCalendarCoverTransitionRuntime {
    /// 根据阶段与进度返回当前帧视觉通道值，避免背景/主体各自跑时钟。
    static func channels(
        phase: ReadCalendarCoverTransitionPhase,
        progress: CGFloat,
        spec: ReadCalendarCoverTransitionSpec
    ) -> ReadCalendarCoverTransitionChannels {
        let p = clamped(progress)
        switch phase {
        case .idle:
            return ReadCalendarCoverTransitionChannels(
                backdropOpacity: 0,
                deckOpacity: 0,
                ghostOpacity: 0,
                chromeOpacity: 0
            )
        case .entering:
            let backdropEnd = normalizedTime(spec.entryBackdropDuration, total: spec.openDuration)
            let deckStart = normalizedTime(spec.entryDeckDelay, total: spec.openDuration)
            let deckEnd = normalizedTime(spec.entryDeckDelay + spec.entryDeckDuration, total: spec.openDuration)
            let ghostStart = normalizedTime(spec.entryGhostFadeDelay, total: spec.openDuration)
            let ghostEnd = normalizedTime(spec.entryGhostFadeDelay + spec.entryGhostFadeDuration, total: spec.openDuration)
            let chromeStart = normalizedTime(spec.entryChromeDelay, total: spec.openDuration)
            let chromeEnd = normalizedTime(spec.entryChromeDelay + spec.entryChromeDuration, total: spec.openDuration)

            let backdrop = smoothStep(from: 0, to: backdropEnd, value: p)
            let deck = smoothStep(from: deckStart, to: deckEnd, value: p)
            let ghost = 1 - smoothStep(from: ghostStart, to: ghostEnd, value: p)
            let chrome = smoothStep(from: chromeStart, to: chromeEnd, value: p)
            return ReadCalendarCoverTransitionChannels(
                backdropOpacity: backdrop,
                deckOpacity: deck,
                ghostOpacity: ghost,
                chromeOpacity: chrome
            )
        case .steady:
            return ReadCalendarCoverTransitionChannels(
                backdropOpacity: 1,
                deckOpacity: 1,
                ghostOpacity: 0,
                chromeOpacity: 1
            )
        case .exiting:
            let reversed = 1 - p
            let backdropEnd = normalizedTime(spec.exitBackdropDuration, total: spec.closeDuration)
            let deckEnd = normalizedTime(spec.exitDeckFadeDuration, total: spec.closeDuration)
            let ghostInStart = normalizedTime(spec.exitGhostFadeInDelay, total: spec.closeDuration)
            let ghostInEnd = normalizedTime(spec.exitGhostFadeInDelay + spec.exitGhostFadeInDuration, total: spec.closeDuration)
            let ghostOutStart = normalizedTime(spec.exitGhostFadeOutDelay, total: spec.closeDuration)
            let ghostOutEnd = normalizedTime(spec.exitGhostFadeOutDelay + spec.exitGhostFadeOutDuration, total: spec.closeDuration)

            let backdrop = 1 - smoothStep(from: 0, to: backdropEnd, value: reversed)
            let deck = 1 - smoothStep(from: 0, to: deckEnd, value: reversed)
            let ghostIn = smoothStep(from: ghostInStart, to: ghostInEnd, value: reversed)
            let ghostOut = smoothStep(from: ghostOutStart, to: ghostOutEnd, value: reversed)
            let ghost = ghostIn * (1 - ghostOut)
            return ReadCalendarCoverTransitionChannels(
                backdropOpacity: backdrop,
                deckOpacity: deck,
                ghostOpacity: ghost,
                chromeOpacity: deck
            )
        }
    }

    /// 返回当前阶段下的面板缩放值，用于保持进退场视觉弹性。
    static func panelScale(
        phase: ReadCalendarCoverTransitionPhase,
        progress: CGFloat,
        spec: ReadCalendarCoverTransitionSpec
    ) -> CGFloat {
        let p = clamped(progress)
        switch phase {
        case .idle:
            return spec.panelEntryScaleFrom
        case .entering:
            return lerp(spec.panelEntryScaleFrom, 1, p)
        case .steady:
            return 1
        case .exiting:
            let exitProgress = smoothStep(from: 0, to: 1, value: 1 - p)
            return lerp(1, spec.panelExitScaleTo, exitProgress)
        }
    }

    /// 返回当前阶段下的面板纵向偏移，用于构建入场上浮与退场下沉。
    static func panelOffsetY(
        phase: ReadCalendarCoverTransitionPhase,
        progress: CGFloat,
        spec: ReadCalendarCoverTransitionSpec
    ) -> CGFloat {
        let p = clamped(progress)
        switch phase {
        case .idle:
            return spec.panelEntryOffsetY
        case .entering:
            return lerp(spec.panelEntryOffsetY, 0, p)
        case .steady:
            return 0
        case .exiting:
            return lerp(spec.panelExitOffsetY, 0, p)
        }
    }

    /// 返回幽灵层旅行进度（0=源位，1=舞台位）。
    static func ghostTravelProgress(
        phase: ReadCalendarCoverTransitionPhase,
        progress: CGFloat
    ) -> CGFloat {
        let p = clamped(progress)
        switch phase {
        case .idle:
            return 0
        case .entering:
            return smoothStep(from: 0, to: 1, value: p)
        case .steady:
            return 1
        case .exiting:
            return smoothStep(from: 0, to: 1, value: p)
        }
    }
}

private extension ReadCalendarCoverTransitionRuntime {
    static func normalizedTime(_ value: Double, total: Double) -> CGFloat {
        guard total > 0 else { return 1 }
        return clamped(CGFloat(value / total))
    }

    static func smoothStep(from: CGFloat, to: CGFloat, value: CGFloat) -> CGFloat {
        guard to > from else { return value >= to ? 1 : 0 }
        let t = clamped((value - from) / (to - from))
        return t * t * (3 - 2 * t)
    }

    static func lerp(_ min: CGFloat, _ max: CGFloat, _ t: CGFloat) -> CGFloat {
        min + (max - min) * clamped(t)
    }

    static func clamped(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}
