/**
 * [INPUT]: 依赖 ContentViewerSourceContext、SwiftUI/UIKit 与 DesignTokens 提供通用查看器共享支撑能力
 * [OUTPUT]: 对外提供 ContentViewerPresentationStyle、占位能力模型、标签弹层、分享面板与共享辅助视图
 * [POS]: Content 模块查看页共享 support，统一书摘/书评/相关内容 viewer 的展示语义与辅助弹层
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 通用内容查看器展示风格，按入口来源决定文案与局部交互语义。
enum ContentViewerPresentationStyle {
    case general
    case noteOnly

    init(source: ContentViewerSourceContext) {
        switch source {
        case .bookNotes:
            self = .noteOnly
        case .timeline(_, _, let filter):
            self = filter == .note ? .noteOnly : .general
        }
    }

    var defaultTitle: String {
        switch self {
        case .general:
            "内容查看"
        case .noteOnly:
            "书摘"
        }
    }

    var missingItemMessage: String {
        switch self {
        case .general:
            "内容不存在或已删除"
        case .noteOnly:
            "书摘不存在或已删除"
        }
    }

    var loadingMessage: String {
        switch self {
        case .general:
            "正在加载内容…"
        case .noteOnly:
            "正在加载书摘…"
        }
    }

    var emptyIconName: String {
        switch self {
        case .general:
            "doc.text.magnifyingglass"
        case .noteOnly:
            "text.quote"
        }
    }

    var deleteDialogTitle: String {
        switch self {
        case .general:
            "删除当前内容？"
        case .noteOnly:
            "删除当前书摘？"
        }
    }

    var deleteAccessibilityLabel: String {
        switch self {
        case .general:
            "删除内容"
        case .noteOnly:
            "删除书摘"
        }
    }

    var showsListErrorBanner: Bool {
        switch self {
        case .general:
            true
        case .noteOnly:
            false
        }
    }
}

/// 通用内容查看未开放能力枚举，统一管理入口提示文案与占位语义。
enum ContentViewerPendingCapability {
    case editTags
    case apiSend
    case aiAssistant
    case aiExplain
    case autoTag
    case shareCard
    case keywordHighlight

    var title: String {
        switch self {
        case .editTags:
            "标签编辑"
        case .apiSend:
            "API 外发"
        case .aiAssistant:
            "AI 助手"
        case .aiExplain:
            "AI 解读"
        case .autoTag:
            "自动标签"
        case .shareCard:
            "分享卡片"
        case .keywordHighlight:
            "关键词高亮"
        }
    }

    var message: String {
        switch self {
        case .editTags:
            "标签编辑能力已预留，后续版本开放。"
        case .apiSend:
            "API 外发能力已预留，后续版本开放。"
        case .aiAssistant:
            "AI 助手能力已预留，后续版本开放。"
        case .aiExplain:
            "AI 解读能力已预留，后续版本开放。"
        case .autoTag:
            "自动标签能力已预留，后续版本开放。"
        case .shareCard:
            "书摘分享卡片能力已预留，后续版本开放。"
        case .keywordHighlight:
            "关键词高亮能力已预留，后续版本开放。"
        }
    }
}

/// 通用内容查看占位提示载体，供 `.alert(item:)` 统一承接。
struct PendingCapabilityPresentation: Identifiable {
    let capability: ContentViewerPendingCapability
    let id = UUID()

    var title: String { capability.title }
    var message: String { capability.message }
}

/// 通用内容查看底部多级动作菜单身份枚举。
enum ContentViewerActionMenu: Identifiable {
    case noteTag
    case noteShare
    case noteAPISend
    case noteAI

    var id: String {
        switch self {
        case .noteTag:
            "noteTag"
        case .noteShare:
            "noteShare"
        case .noteAPISend:
            "noteAPISend"
        case .noteAI:
            "noteAI"
        }
    }
}

/// 标签查看弹层，统一承接书摘标签只读浏览体验。
struct ContentViewerTagSheet: View {
    let tags: [String]
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.base) {
                if tags.isEmpty {
                    Text("当前书摘没有标签")
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    FlowTagWrap(tags: tags)
                }

                Spacer(minLength: 0)
            }
            .padding(Spacing.screenEdge)
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: onDismiss)
                }
            }
        }
    }
}

/// 简单流式标签换行视图，保持 viewer 标签展示密度稳定。
struct FlowTagWrap: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(chunkedTags, id: \.self) { row in
                HStack(spacing: Spacing.cozy) {
                    ForEach(row, id: \.self) { tag in
                        Text(tag)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textPrimary)
                            .padding(.horizontal, Spacing.cozy)
                            .padding(.vertical, Spacing.compact)
                            .background(Color.tagBackground, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var chunkedTags: [[String]] {
        stride(from: 0, to: tags.count, by: 3).map { index in
            Array(tags[index..<min(index + 3, tags.count)])
        }
    }
}

/// 分享弹层 payload，统一作为 `.sheet(item:)` 身份载体。
struct ContentViewerSharePayload: Identifiable {
    let text: String
    let id = UUID()
}

/// UIKit 分享面板桥接，供 viewer 分享与复制扩展复用。
struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
