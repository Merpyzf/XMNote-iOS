/**
 * [INPUT]: 依赖 UIKit Share Extension 生命周期、UniformTypeIdentifiers 与 App Group handoff store，接收宿主 App 传入的文本或 URL item
 * [OUTPUT]: 对外提供 ShareViewController，在系统分享面板内识别微信读书书单链接、写入 handoff，并请求打开主 App 继续导入
 * [POS]: XMNoteShareExtension 的扩展入口控制器，只负责系统分享接收与轻量反馈，不访问主 App 数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit
import UniformTypeIdentifiers

/// 系统分享扩展入口，接收微信读书分享文本并交给主 App 完成书单导入。
final class ShareViewController: UIViewController {
    private let handoffStore = BookCollectionShareImportHandoffStore()
    private let statusLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        receiveSharedContent()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        statusLabel.text = "正在识别微信读书书单…"
        statusLabel.textColor = .label
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        activityIndicator.startAnimating()

        let stackView = UIStackView(arrangedSubviews: [activityIndicator, statusLabel])
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func receiveSharedContent() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let link = try await loadWereadCollectionLink()
                try handoffStore.save(link: link)
                await openContainingApp()
            } catch {
                showFailure(error.localizedDescription)
            }
        }
    }

    /// 异步读取宿主传入的 item provider；任务取消时不写入 handoff，避免半成品请求残留。
    private func loadWereadCollectionLink() async throws -> String {
        let providers = extensionContext?
            .inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        for provider in providers {
            if let link = try await loadLink(from: provider) {
                return link
            }
        }
        throw BookCollectionShareImportHandoffError.invalidWereadLink
    }

    private func loadLink(from provider: NSItemProvider) async throws -> String? {
        let typeIdentifiers = [
            UTType.url.identifier,
            UTType.plainText.identifier,
            UTType.text.identifier,
            "public.url",
            "public.plain-text",
            "public.text"
        ]

        for typeIdentifier in typeIdentifiers where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            if let link = try await loadLink(from: provider, typeIdentifier: typeIdentifier) {
                return link
            }
        }
        return nil
    }

    private func loadLink(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let link: String?
                switch item {
                case let url as URL:
                    link = WereadCollectionLinkExtractor.extractLink(from: url)
                case let text as String:
                    link = WereadCollectionLinkExtractor.extractLink(from: text)
                case let data as Data:
                    link = String(data: data, encoding: .utf8)
                        .flatMap(WereadCollectionLinkExtractor.extractLink(from:))
                default:
                    link = nil
                }
                continuation.resume(returning: link)
            }
        }
    }

    @MainActor
    private func openContainingApp() {
        statusLabel.text = "已接收书单，正在打开纸间书摘…"
        guard let url = URL(string: "xmnote://import-weread?source=share-extension") else {
            completeRequest()
            return
        }
        extensionContext?.open(url) { [weak self] _ in
            self?.completeRequest()
        }
    }

    @MainActor
    private func showFailure(_ message: String) {
        activityIndicator.stopAnimating()
        statusLabel.text = message
        let button = UIButton(type: .system)
        button.setTitle("关闭", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addAction(UIAction { [weak self] _ in
            self?.completeRequest()
        }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 24),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    @MainActor
    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
