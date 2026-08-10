/**
 * [INPUT]: 接收已转换为纯文本的书摘正文与想法，依赖 AVFAudio 提供系统语音合成与队列控制
 * [OUTPUT]: 对外提供 NoteSpeechController，统一书摘朗读的开始、暂停、继续、停止与页面退出释放语义
 * [POS]: Services 层书摘系统朗读控制器，由 ContentViewer 页面持有并随页面生命周期释放
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import AVFAudio
import Foundation

/// 书摘系统朗读控制器；所有可观察状态与 AVSpeechSynthesizer 操作均归属主线程。
@MainActor
@Observable
final class NoteSpeechController: NSObject, AVSpeechSynthesizerDelegate {
    /// 当前朗读阶段，供界面在同一入口中切换开始、暂停、继续与停止动作。
    enum State: Equatable {
        case idle
        case speaking
        case paused
    }

    private(set) var state: State = .idle

    private var synthesizer: AVSpeechSynthesizer?
    private var activeUtteranceID: ObjectIdentifier?

    /// 停止旧队列后朗读正文与想法；空内容不会创建系统朗读队列。
    ///
    /// 新请求采用 newest-wins：旧队列立即取消并释放，新队列才开始。此同步方法不创建后台任务，
    /// 系统合成过程由 AVSpeechSynthesizer 管理，页面退出时调用 `release()` 取消未完成朗读。
    @discardableResult
    func start(content: String, idea: String) -> Bool {
        let speechText = Self.makeSpeechText(content: content, idea: idea)
        guard !speechText.isEmpty else {
            release()
            return false
        }

        release()

        let nextSynthesizer = AVSpeechSynthesizer()
        nextSynthesizer.delegate = self

        let utterance = AVSpeechUtterance(string: speechText)
        if let preferredLanguage = Locale.preferredLanguages.first,
           let preferredVoice = AVSpeechSynthesisVoice(language: preferredLanguage) {
            utterance.voice = preferredVoice
        }

        synthesizer = nextSynthesizer
        activeUtteranceID = ObjectIdentifier(utterance)
        state = .speaking
        nextSynthesizer.speak(utterance)
        return true
    }

    /// 在当前单词边界暂停朗读；系统拒绝暂停时维持原状态。
    func pause() {
        guard state == .speaking, let synthesizer else { return }
        guard synthesizer.pauseSpeaking(at: .word) else { return }
        state = .paused
    }

    /// 从系统记录的暂停位置继续朗读；队列已失效时回到空闲态。
    func resume() {
        guard state == .paused, let synthesizer else { return }
        guard synthesizer.continueSpeaking() else {
            release()
            return
        }
        state = .speaking
    }

    /// 立即停止当前朗读并清空系统队列，避免翻页后继续播报上一条书摘。
    func stop() {
        release()
    }

    /// 页面退出或启动新队列时取消未完成朗读，并解除 delegate 后释放 synthesizer。
    func release() {
        let previousSynthesizer = synthesizer
        synthesizer = nil
        activeUtteranceID = nil
        state = .idle

        previousSynthesizer?.delegate = nil
        if previousSynthesizer?.isSpeaking == true {
            previousSynthesizer?.stopSpeaking(at: .immediate)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        completeSpeechFromDelegate(utteranceID: ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        completeSpeechFromDelegate(utteranceID: ObjectIdentifier(utterance))
    }
}

private extension NoteSpeechController {
    /// Delegate 回调可能不在主线程；只传递 Sendable 身份值回主 Actor，并忽略已被新请求替换的旧回调。
    nonisolated func completeSpeechFromDelegate(utteranceID: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, activeUtteranceID == utteranceID else { return }
            release()
        }
    }

    static func makeSpeechText(content: String, idea: String) -> String {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []
        if !normalizedContent.isEmpty {
            sections.append(normalizedContent)
        }
        if !normalizedIdea.isEmpty {
            sections.append("想法。\(normalizedIdea)")
        }
        return sections.joined(separator: "。\n")
    }
}
