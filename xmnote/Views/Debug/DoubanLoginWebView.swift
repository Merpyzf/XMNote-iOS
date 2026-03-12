#if DEBUG
import SwiftUI
import WebKit

/**
 * [INPUT]: 依赖 DoubanWebLoginService 提供共享豆瓣会话与登录请求，依赖 WKWebView 承载豆瓣登录流程
 * [OUTPUT]: 对外提供 DoubanLoginWebViewScreen（Debug 豆瓣登录页）与 DoubanLoginWebView（WKWebView 桥接）
 * [POS]: Debug 网页抓取测试页的豆瓣登录入口，用共享会话完成登录并回流到抓取测试页
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct DoubanLoginWebViewScreen: View {
    let title: String
    let onClose: () -> Void
    let onLoginDetected: () -> Void

    var body: some View {
        NavigationStack {
            DoubanLoginWebView(onLoginDetected: onLoginDetected)
                .background(Color.surfacePage)
                .navigationTitle("登录豆瓣")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭", action: onClose)
                    }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 2) {
                            Text("登录豆瓣")
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

private struct DoubanLoginWebView: UIViewRepresentable {
    let onLoginDetected: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginDetected: onLoginDetected)
    }

    func makeUIView(context: Context) -> WKWebView {
        let service = DoubanWebLoginService.shared
        let webView = WKWebView(frame: .zero, configuration: service.makeWebViewConfiguration())
        webView.customUserAgent = XMImageRequestBuilder.browserUserAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.load(service.makeLoginRequest())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoginDetected: () -> Void
        private var hasReportedSuccess = false

        init(onLoginDetected: @escaping () -> Void) {
            self.onLoginDetected = onLoginDetected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                guard hasReportedSuccess == false else { return }
                let isLoggedIn = await DoubanWebLoginService.shared.isLoggedIn()
                guard isLoggedIn else { return }
                hasReportedSuccess = true
                onLoginDetected()
            }
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
#endif
