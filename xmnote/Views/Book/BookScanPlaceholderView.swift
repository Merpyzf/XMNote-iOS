/**
 * [INPUT]: 依赖 VisionKit DataScannerViewController 识别条码，接收 BookSearchView 注入的 ISBN 回填闭包
 * [OUTPUT]: 对外提供 BookScanPlaceholderView，承接“扫码录入”入口并将有效 ISBN 回填到搜索页
 * [POS]: Book 模块添加书籍扫码页面，在扫码不可用时提供手动 ISBN 兜底
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import Vision
import VisionKit

/// ISBN 扫码页，优先使用系统相机条码识别，无法使用相机时保留手动 ISBN 输入。
struct BookScanPlaceholderView: View {
    let onISBNScanned: (String) -> Void

    @State private var manualISBN = ""
    @State private var feedback: String?

    init(onISBNScanned: @escaping (String) -> Void = { _ in }) {
        self.onISBNScanned = onISBNScanned
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                scannerSection
                manualSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.screenEdge)
        }
        .scrollIndicators(.hidden)
        .background(Color.surfacePage)
        .navigationTitle("扫码录入")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var scannerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text("扫描 ISBN 条码")
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(Color.textPrimary)

            ZStack {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    BookISBNScannerRepresentable(
                        onCodeDetected: submitISBNCandidate(_:),
                        onError: { feedback = $0 }
                    )
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
                    .overlay(scanGuide)
                } else {
                    scannerUnavailableView
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }

            if let feedback {
                Text(feedback)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.contentEdge)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text("手动输入 ISBN")
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(Color.textPrimary)

            HStack(spacing: Spacing.cozy) {
                TextField("ISBN", text: $manualISBN)
                    .font(AppTypography.body)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .padding(.horizontal, Spacing.base)
                    .frame(minHeight: 44)
                    .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))

                Button("搜索") {
                    submitISBNCandidate(manualISBN)
                }
                .font(AppTypography.bodyMedium)
                .buttonStyle(.borderedProminent)
                .disabled(normalizedISBN(manualISBN) == nil)
            }
        }
        .padding(Spacing.contentEdge)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
    }

    private var scanGuide: some View {
        VStack(spacing: Spacing.compact) {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.brand, lineWidth: 2)
                .frame(width: 240, height: 128)
            Text("将书背或封底条码置于框内")
                .font(AppTypography.captionMedium)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.tiny)
                .background(Color.black.opacity(0.45), in: Capsule())
        }
        .allowsHitTesting(false)
    }

    private var scannerUnavailableView: some View {
        VStack(spacing: Spacing.cozy) {
            Image(systemName: "camera.viewfinder")
                .font(AppTypography.title2)
                .foregroundStyle(Color.textSecondary)
            Text("当前设备或相机权限暂不可用")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
            Text("可以在系统设置中允许相机访问，或直接输入 ISBN。")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Spacing.contentEdge)
    }

    private func submitISBNCandidate(_ candidate: String) {
        guard let isbn = normalizedISBN(candidate) else {
            feedback = "请扫描或输入 10 位/13 位 ISBN。"
            return
        }
        feedback = "已识别 ISBN：\(isbn)"
        onISBNScanned(isbn)
    }

    private func normalizedISBN(_ rawValue: String) -> String? {
        let normalized = rawValue
            .uppercased()
            .filter { character in
                character.isNumber || character == "X"
            }
        guard normalized.count == 10 || normalized.count == 13 else { return nil }
        return normalized
    }
}

/// VisionKit 条码扫描器桥接，负责把系统识别结果转成字符串回调。
private struct BookISBNScannerRepresentable: UIViewControllerRepresentable {
    let onCodeDetected: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.ean13, .ean8, .upce, .code128, .code39, .qr])
            ],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        do {
            try controller.startScanning()
        } catch {
            onError("扫码启动失败：\(error.localizedDescription)")
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeDetected: onCodeDetected)
    }

    /// DataScanner delegate，去重后把新增或点击的条码传给 SwiftUI 页面。
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCodeDetected: (String) -> Void
        private var latestCode: String?

        init(onCodeDetected: @escaping (String) -> Void) {
            self.onCodeDetected = onCodeDetected
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(items: addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle(item: item)
        }

        private func handle(items: [RecognizedItem]) {
            for item in items {
                handle(item: item)
            }
        }

        private func handle(item: RecognizedItem) {
            guard case .barcode(let barcode) = item,
                  let payload = barcode.payloadStringValue,
                  payload != latestCode else {
                return
            }
            latestCode = payload
            onCodeDetected(payload)
        }
    }
}

#Preview {
    NavigationStack {
        BookScanPlaceholderView()
    }
}
