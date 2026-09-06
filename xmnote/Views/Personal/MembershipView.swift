/**
 * [INPUT]: 依赖 MembershipStore、项目 Settings 组件与系统确认弹窗
 * [OUTPUT]: 提供永久会员状态、购买/恢复与 Debug 模拟控制页面
 * [POS]: Views/Personal 的会员流程 owner，页面不写权益或存储
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import SwiftUI

/// 会员管理始终可进入；购买任务交给应用状态层，返回不清除已持久化权益。
struct MembershipView: View {
    @Environment(MembershipStore.self) private var membership
    #if DEBUG
    @State private var showsPurchaseConfirmation = false
    @State private var nextOutcome = MembershipSimulationOutcome.success
    #endif

    var body: some View {
        XMSettingsPage {
            XMSettingsSection("会员状态") {
                XMSettingsGroup {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Text(membership.title).font(AppTypography.title2)
                        if let date = membership.snapshot.entitlement.purchasedAt {
                            Text("开通时间：\(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
                        }
                        Text("一次开通，永久使用。退款或权益撤销后将恢复免费版。")
                            .font(AppTypography.body)
                        if membership.snapshot.operation != nil {
                            ProgressView(operationTitle)
                        }
                        if let message = membership.snapshot.message {
                            XMInlineStatusBanner(message)
                        }
                        if let error = membership.snapshot.errorMessage {
                            XMInlineStatusBanner(error, tone: .error)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            XMSettingsSection("永久会员权益") {
                XMSettingsGroup {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Text("微信读书授权与 API 导入")
                        Text("桌面网页编辑与默认图床会员额度")
                        Text("全部历史阅读日历与高级分享选项")
                    }
                    .font(AppTypography.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            XMSettingsGroup {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    #if DEBUG
                    Text("开发模拟，不会实际扣费")
                        .font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
                    #else
                    Text("Apple 支付暂未开放")
                        .font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
                    #endif
                    Button(action: beginPurchase) {
                        Text(purchaseTitle)
                            .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget)
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appTint)
                        .foregroundStyle(Color.primaryActionForeground)
                        .disabled(!canPurchase)
                    actionRow("恢复购买") { Task { await membership.restore() } }
                        .disabled(membership.snapshot.operation != nil)
                    actionRow("刷新会员状态") { Task { await membership.refresh() } }
                        .disabled(membership.snapshot.operation != nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if DEBUG
            if membership.product?.isSimulation == true { simulationSection }
            #endif
        }
        .tint(Color.textPrimary)
        .navigationTitle("会员")
        .navigationBarTitleDisplayMode(.inline)
        .task { await membership.start() }
        #if DEBUG
        .xmSystemAlert(isPresented: $showsPurchaseConfirmation, descriptor: .init(
            title: "模拟开通永久会员",
            message: "本次仅用于开发测试，不会实际扣费。",
            actions: [
                .init(title: "取消", role: .cancel) {},
                .init(title: "确认模拟支付") {
                    Task {
                        await membership.simulate(.nextOutcome(nextOutcome))
                        await membership.purchase()
                        nextOutcome = .success
                    }
                }
            ]
        ))
        #endif
    }

    /// 模拟购买需要明确确认；未来真实来源直接交由支付适配器呈现系统购买确认。
    private func beginPurchase() {
        guard canPurchase else { return }
        #if DEBUG
        if membership.product?.isSimulation == true {
            showsPurchaseConfirmation = true
            return
        }
        #endif
        Task { await membership.purchase() }
    }

    /// 会员页次级动作保持中性整行点击区，不以较小的文字尺寸缩小触摸范围。
    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.body)
                .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canPurchase: Bool {
        membership.product?.purchaseAvailable == true && membership.snapshot.isLoaded
            && membership.snapshot.operation == nil && !membership.isPremium
            && !membership.snapshot.entitlement.hasPendingPurchase
    }
    private var purchaseTitle: String {
        if membership.isPremium { return "已开通永久会员" }
        if membership.snapshot.entitlement.hasPendingPurchase { return "等待支付确认" }
        #if DEBUG
        if membership.product?.isSimulation == true { return "模拟开通永久会员" }
        #endif
        return membership.product?.purchaseAvailable == true ? "开通永久会员" : "暂未开放"
    }
    private var operationTitle: String {
        switch membership.snapshot.operation {
        case .purchasing: "正在处理支付…"
        case .restoring: "正在恢复购买…"
        case .refreshing, nil: "正在核对会员状态…"
        }
    }

    #if DEBUG
    private var simulationSection: some View {
        XMSettingsSection("开发测试") {
            XMSettingsGroup {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    XMSettingsValueMenuRow(
                        title: "下次支付结果", value: nextOutcome.rawValue,
                        options: MembershipSimulationOutcome.allCases, selection: nextOutcome,
                        optionTitle: { $0.rawValue }, optionImage: { _ in nil },
                        onSelect: { nextOutcome = $0 }
                    )
                    if membership.snapshot.entitlement.hasPendingPurchase {
                        actionRow("确认待处理支付") { Task { await membership.simulate(.approvePending) } }
                        actionRow("拒绝待处理支付") { Task { await membership.simulate(.rejectPending) } }
                    }
                    actionRow("模拟撤销会员权益") { Task { await membership.simulate(.revoke) } }
                        .disabled(!membership.isPremium)
                    actionRow("重置为未购买") {
                        Task { await membership.simulate(.reset); nextOutcome = .success }
                    }
                    Text("失效模拟退款或权益撤销。重置仅改变开发交易记录，不修改书籍和笔记。")
                        .font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(membership.snapshot.operation != nil)
            }
        }
    }
    #endif
}
