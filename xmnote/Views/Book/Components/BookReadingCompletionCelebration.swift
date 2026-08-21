/**
 * [INPUT]: 依赖 Vortex 1.0.4 内建 fireworks/confetti/magic 系统、BookReadingCompletionTracker 与系统辅助功能/生命周期环境
 * [OUTPUT]: 对外提供 BookReadingCompletionCelebration，仅用于阅读详情新增读完状态并成功评分后的全屏庆祝
 * [POS]: Views/Book/Components 页面私有庆祝层，不承担状态写入，也不作为跨模块公共粒子基建
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import Vortex

/// 三秒全屏庆祝层；粒子系统只在非 Reduce Motion 分支挂载，退场或进入后台立即停止。
struct BookReadingCompletionCelebration: View {
    let tracker: BookReadingCompletionTracker
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var fireworksSystem: VortexSystem
    @State private var confettiSystem: VortexSystem
    @State private var magicSystem: VortexSystem
    @State private var didBurstConfetti = false
    @State private var feedbackTrigger = false
    @State private var isContentVisible = false
    @State private var overlayOpacity = 1.0

    /// 为每次庆祝创建独立系统，避免 Vortex 静态预设在多次展示间共享粒子和 emissionCount。
    init(tracker: BookReadingCompletionTracker, onDismiss: @escaping () -> Void) {
        self.tracker = tracker
        self.onDismiss = onDismiss
        _fireworksSystem = State(initialValue: VortexSystem.fireworks.makeUniqueCopy())
        _confettiSystem = State(initialValue: VortexSystem.confetti.makeUniqueCopy())
        _magicSystem = State(initialValue: VortexSystem.magic.makeUniqueCopy())
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.87)
                .ignoresSafeArea()

            if accessibilityReduceMotion {
                celebrationMessage
                    .opacity(isContentVisible ? 1 : 0)
            } else {
                particleLayers
                    .accessibilityHidden(true)

                celebrationMessage
                    .scaleEffect(isContentVisible ? 1 : 0.9)
                    .opacity(isContentVisible ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .opacity(overlayOpacity)
        .sensoryFeedback(.success, trigger: feedbackTrigger)
        .accessibilityElement(children: .contain)
        // SwiftUI 主任务控制三秒驻留；页面退场会取消睡眠，系统停止由 onDisappear 兜底。
        .task {
            feedbackTrigger.toggle()
            withAnimation(accessibilityReduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.5, bounce: 0.28)) {
                isContentVisible = true
            }
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                overlayOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            stopParticleSystems()
            onDismiss()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            stopParticleSystems()
            onDismiss()
        }
        .onDisappear(perform: stopParticleSystems)
    }

    private var particleLayers: some View {
        ZStack {
            VortexView(fireworksSystem, targetFrameRate: 60) {
                Circle()
                    .fill(.white)
                    .blendMode(.plusLighter)
                    .frame(width: 24)
                    .tag("circle")
            }
            .ignoresSafeArea()

            VortexViewReader { proxy in
                VortexView(confettiSystem, targetFrameRate: 60) {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 14, height: 8)
                        .tag("square")
                    Circle()
                        .fill(.white)
                        .frame(width: 11)
                        .tag("circle")
                }
                .task(id: proxy.particleSystem?.id) {
                    guard proxy.particleSystem != nil, !didBurstConfetti else { return }
                    didBurstConfetti = true
                    proxy.burst()
                }
            }
            .ignoresSafeArea()

            VortexView(magicSystem, targetFrameRate: 60) {
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
                    .font(AppTypography.title2)
                    .blendMode(.plusLighter)
                    .tag("sparkle")
            }
            .frame(width: 270, height: 270)
        }
    }

    private var celebrationMessage: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "checkmark.seal.fill")
                .font(AppTypography.largeTitle)
                .foregroundStyle(Color.statusDone)
                .accessibilityHidden(true)

            Text("恭喜读完一本书")
                .font(AppTypography.title2)
                .foregroundStyle(.white)

            Text("累计读完 \(tracker.totalCompletedBookCount) 本 · 今年 \(tracker.completedBookCountThisYear)/\(tracker.targetBookCountThisYear) 本")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(.white.opacity(0.78))
                .monospacedDigit()
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.double)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("恭喜读完一本书。累计读完 \(tracker.totalCompletedBookCount) 本，今年 \(tracker.completedBookCountThisYear) 本，年度目标 \(tracker.targetBookCountThisYear) 本。")
    }

    /// 关闭所有 Vortex 系统；类实例仍由当前视图持有，视图释放后随之回收。
    private func stopParticleSystems() {
        fireworksSystem.isActive = false
        confettiSystem.isActive = false
        magicSystem.isActive = false
    }
}
