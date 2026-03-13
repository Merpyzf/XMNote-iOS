/**
 * [INPUT]: 依赖 FanqieWebVerificationService 提供共享番茄会话与验证页请求，依赖 WKWebView 承载站点验证流程
 * [OUTPUT]: 对外提供 BookFanqieVerificationScreen，承接番茄搜索风控后的验证页与验证成功回流
 * [POS]: Book/Sheets 业务弹层，负责搜索页番茄验证入口与验证回流的统一承载
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import WebKit

/// 番茄验证全屏页，承接真实站点验证并在验证完成后回流搜索页。
struct BookFanqieVerificationScreen: View {
    let title: String
    let searchURL: URL
    let onClose: () -> Void
    let onVerificationCompleted: () -> Void

    var body: some View {
        NavigationStack {
            BookFanqieVerificationWebView(
                searchURL: searchURL,
                onVerificationCompleted: onVerificationCompleted
            )
            .background(Color.surfacePage)
            .navigationTitle("番茄验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", action: onClose)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("番茄验证")
                            .font(.headline)
                        Text(title)
                            .font(.caption2)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct BookFanqieVerificationWebView: UIViewRepresentable {
    let searchURL: URL
    let onVerificationCompleted: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVerificationCompleted: onVerificationCompleted)
    }

    func makeUIView(context: Context) -> WKWebView {
        let service = FanqieWebVerificationService.shared
        let webView = WKWebView(frame: .zero, configuration: service.makeWebViewConfiguration())
        webView.customUserAgent = XMImageRequestBuilder.browserUserAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.load(service.makeRequest(url: searchURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onVerificationCompleted: () -> Void
        private var hasReportedCompletion = false

        init(onVerificationCompleted: @escaping () -> Void) {
            self.onVerificationCompleted = onVerificationCompleted
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                guard hasReportedCompletion == false else { return }

                let html = (try? await evaluateString(webView, script: "document.documentElement.outerHTML")) ?? ""
                guard FanqieVerificationHeuristics.requiresVerification(html: html, finalURL: webView.url) == false else {
                    return
                }
                guard FanqieVerificationHeuristics.isSearchPage(url: webView.url) else {
                    return
                }

                hasReportedCompletion = true
                onVerificationCompleted()
            }
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            completionHandler(.performDefaultHandling, nil)
        }

        private func evaluateString(_ webView: WKWebView, script: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: value as? String ?? "")
                }
            }
        }
    }
}
