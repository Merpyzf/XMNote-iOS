/**
 * [INPUT]: 依赖 WebKit、WereadWebAuthorizationService 与授权页回调，加载微信读书桌面登录页
 * [OUTPUT]: 对外提供 WereadAuthorizationWebView，轮询二维码 DOM、Cookie、失效文案与网页错误
 * [POS]: Views/Personal/DataImport 的 UIKit-WebKit 桥接组件，不承载导入业务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import WebKit

struct WereadAuthorizationWebView: UIViewRepresentable {
    let reloadToken: UUID
    let onQRCode: (Data?) -> Void
    let onCookie: (String) -> Void
    let onExpired: () -> Void
    let onFailed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let service = WereadWebAuthorizationService.shared
        let configuration = service.makeConfiguration()
        configuration.userContentController.add(context.coordinator, name: Coordinator.messageName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
                (() => {
                  const notify = () => window.webkit.messageHandlers.wereadAuthorization.postMessage('documentChanged');
                  new MutationObserver(notify).observe(document.documentElement, { subtree: true, childList: true, attributes: true });
                  window.addEventListener('hashchange', notify);
                  window.addEventListener('pageshow', notify);
                })();
                """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = WereadWebAuthorizationService.desktopUserAgent
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(service.makeLoginRequest())
        context.coordinator.startPolling()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            webView.load(WereadWebAuthorizationService.shared.makeLoginRequest())
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.pollTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
        webView.stopLoading(); webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageName = "wereadAuthorization"
        var parent: WereadAuthorizationWebView
        weak var webView: WKWebView?
        var pollTask: Task<Void, Never>?
        var reloadToken: UUID
        private var lastQRCode: String?
        private var lastCookie = ""

        init(parent: WereadAuthorizationWebView) { self.parent = parent; reloadToken = parent.reloadToken }

        func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.inspect()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Task { await inspect() } }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.onFailed(error.localizedDescription) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.onFailed(error.localizedDescription) }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageName else { return }
            Task { await inspect() }
        }

        private func inspect() async {
            guard let webView else { return }
            let script = """
                (() => {
                  const text = document.body ? document.body.innerText : '';
                  const img = [...document.images].find(i => (i.src || '').startsWith('data:image') && (i.width > 120 || i.naturalWidth > 120));
                  const canvas = [...document.querySelectorAll('canvas')].find(c => c.width > 120);
                  let qr = img ? img.src : null;
                  if (!qr && canvas) { try { qr = canvas.toDataURL('image/png'); } catch (_) {} }
                  return JSON.stringify({ qr, expired: text.includes('二维码已失效') || text.includes('二维码过期') });
                })()
                """
            if let json = try? await webView.evaluateJavaScript(script) as? String,
               let data = json.data(using: .utf8),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if result["expired"] as? Bool == true { parent.onExpired() }
                if let source = result["qr"] as? String, source != lastQRCode {
                    lastQRCode = source
                    let base64 = source.components(separatedBy: ",").last ?? ""
                    parent.onQRCode(Data(base64Encoded: base64))
                }
            }
            let cookie = await WereadWebAuthorizationService.shared.cookieHeader()
            if cookie != lastCookie { lastCookie = cookie; parent.onCookie(cookie) }
        }
    }
}
