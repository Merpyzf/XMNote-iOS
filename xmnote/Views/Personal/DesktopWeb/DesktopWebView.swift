/**
 * [INPUT]: 依赖 App 环境中的 DesktopWebSessionCoordinator、Core Image 二维码与 XMSystemAlert
 * [OUTPUT]: 对外提供网页端正式页面，展示网页服务开关、状态、局域网地址、复制/二维码和阶段边界
 * [POS]: Views/Personal/DesktopWeb 的页面壳层；只控制 App 级会话，不持有 HTTP 服务生命周期
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// 网页端首期入口，明确区分静态网页已运行与业务接口尚未迁移两种能力边界。
struct DesktopWebView: View {
    @Environment(DesktopWebSessionCoordinator.self) private var coordinator
    @Environment(\.openURL) private var openURL
    @State private var presentedError: DesktopWebErrorPresentation?

    var body: some View {
        @Bindable var coordinator = coordinator

        List {
            serviceSection(coordinator: coordinator)
            endpointSection
            capabilityNoticeSection
            usageNoticeSection
        }
        .navigationTitle("网页端")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.smooth, value: coordinator.state)
        .onChange(of: coordinator.state) { _, state in
            guard case .failed(let message) = state else { return }
            presentedError = DesktopWebErrorPresentation(message: message)
        }
        .xmSystemAlert(item: $presentedError) { presentation in
            errorDescriptor(for: presentation)
        }
    }

    /// 组合开关、运行状态与发现名称，切换期间禁用重复触发。
    private func serviceSection(coordinator: DesktopWebSessionCoordinator) -> some View {
        Section("网页端服务") {
            Toggle(
                "允许同一局域网的电脑访问",
                isOn: Binding(
                    get: { coordinator.isEnabled },
                    set: { coordinator.setEnabled($0) }
                )
            )
            .disabled(coordinator.state.isTransitioning)

            LabeledContent("状态") {
                Label(stateText, systemImage: stateIcon)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(stateColor)
                    .symbolEffect(.pulse, isActive: coordinator.state.isTransitioning)
            }

            if let serviceName = coordinator.bonjourServiceName {
                LabeledContent("Bonjour", value: serviceName)
            }

            if case .failed(let message) = coordinator.state {
                Text(message)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.feedbackError)
                Button("重新尝试") {
                    coordinator.retry()
                }
            }
        }
    }

    /// 运行时展示全部有效 IPv4 地址，并为首选地址提供二维码；无地址时解释 Wi-Fi 前置条件。
    @ViewBuilder
    private var endpointSection: some View {
        switch coordinator.state {
        case .running(let endpoints):
            Section("访问地址") {
                ForEach(endpoints) { endpoint in
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Text(endpoint.displayName)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                        Text(endpoint.url.absoluteString)
                            .font(AppTypography.callout.monospaced())
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                        HStack(spacing: Spacing.base) {
                            Button {
                                UIPasteboard.general.string = endpoint.url.absoluteString
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)

                            Button {
                                openURL(endpoint.url)
                            } label: {
                                Label("本机打开", systemImage: "safari")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, Spacing.compact)
                }

                if let firstEndpoint = endpoints.first {
                    DesktopWebQRCodeView(url: firstEndpoint.url)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("网页访问地址二维码")
                        .accessibilityValue(firstEndpoint.url.absoluteString)
                }
            }
        case .waitingForLocalNetwork:
            Section("访问地址") {
                ContentUnavailableView(
                    "等待局域网",
                    systemImage: "wifi.exclamationmark",
                    description: Text("请连接 Wi-Fi，并在系统设置中允许 XMNote 访问本地网络。")
                )
            }
        default:
            EmptyView()
        }
    }

    /// 固定展示首期能力边界，避免网页壳可打开被误解为业务迁移完成。
    private var capabilityNoticeSection: some View {
        Section("当前阶段") {
            Label {
                Text("当前仅完成网页运行基础设施，数据、搜索、编辑、导入导出等接口尚未接入。")
                    .font(AppTypography.callout)
                    .foregroundStyle(Color.textPrimary)
            } icon: {
                Image(systemName: "hammer")
                    .foregroundStyle(Color.feedbackWarning)
            }
        }
    }

    /// 说明前台运行与耗电约束，不承诺 iOS 不允许的后台常驻行为。
    private var usageNoticeSection: some View {
        Section("使用说明") {
            Text("服务开启时会阻止自动锁屏并增加耗电。切换 App 内页面不会中断；进入后台、手动锁屏或断开局域网后服务会停止，回到前台将按开关自动恢复。")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
            Text("电脑与 iPhone 需位于同一 Wi-Fi。Bonjour 名称可能因同名设备自动变化，请以页面显示的 IP 地址或二维码为准。")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var stateText: String {
        switch coordinator.state {
        case .stopped:
            return "已停止"
        case .starting:
            return "正在启动"
        case .waitingForLocalNetwork:
            return "等待局域网"
        case .running:
            return "运行中"
        case .stopping:
            return "正在停止"
        case .failed:
            return "启动失败"
        }
    }

    private var stateIcon: String {
        switch coordinator.state {
        case .running:
            return "checkmark.circle.fill"
        case .starting, .stopping:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .waitingForLocalNetwork:
            return "wifi.exclamationmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .stopped:
            return "stop.circle"
        }
    }

    private var stateColor: Color {
        switch coordinator.state {
        case .running:
            return .feedbackSuccess
        case .failed:
            return .feedbackError
        case .waitingForLocalNetwork:
            return .feedbackWarning
        default:
            return .textSecondary
        }
    }

    /// 使用系统弹窗提供重试与权限设置入口，普通动作保持系统默认颜色语义。
    private func errorDescriptor(for presentation: DesktopWebErrorPresentation) -> XMSystemAlertDescriptor {
        var actions = [
            XMSystemAlertAction(title: "重新尝试") {
                coordinator.retry()
            }
        ]
        if presentation.shouldOfferSettings {
            actions.append(
                XMSystemAlertAction(title: "打开设置") {
                    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(settingsURL)
                }
            )
        }
        actions.append(XMSystemAlertAction(title: "取消", role: .cancel) {})
        return XMSystemAlertDescriptor(
            title: "网页服务未能启动",
            message: presentation.message,
            actions: actions
        )
    }
}

/// 系统弹窗 item，确保同一错误状态只触发一次展示周期。
private struct DesktopWebErrorPresentation: Identifiable {
    let id = UUID()
    let message: String

    var shouldOfferSettings: Bool {
        message.contains("本地网络") || message.contains("权限") || message.contains("系统设置")
    }
}

/// 使用 Core Image 在本地生成高对比度二维码，不上传地址且不引入第三方依赖。
private struct DesktopWebQRCodeView: View {
    let image: UIImage?

    init(url: URL) {
        self.image = Self.makeImage(from: url.absoluteString)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
            } else {
                ContentUnavailableView("二维码生成失败", systemImage: "qrcode")
            }
        }
        .padding(.vertical, Spacing.base)
    }

    /// 在主线程生成短小 CIImage 并转为不可变 CGImage，视图销毁后无需取消后台任务。
    private static func makeImage(from value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
