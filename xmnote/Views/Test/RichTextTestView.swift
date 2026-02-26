//
//  RichTextTestView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

import SwiftUI

// MARK: - 外壳

/// 富文本编辑器测试页，验证所有格式能力与 HTML 往返一致性
struct RichTextTestView: View {

    @State private var viewModel = RichTextTestViewModel()

    var body: some View {
        RichTextTestContentView(viewModel: viewModel)
    }
}

// MARK: - 内容子视图

private struct RichTextTestContentView: View {

    @Bindable var viewModel: RichTextTestViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.double) {
                    sampleLoaderSection
                    contentEditorSection
                    highlightColorSection
                    ideaEditorSection
                    htmlOutputSection
                    roundTripSection
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
                .safeAreaPadding(.bottom)
            }
            .background(Color.windowBackground)
            .navigationTitle("富文本编辑器测试")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 示例加载器

    private var sampleLoaderSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("示例 HTML")

                Picker("选择示例", selection: $viewModel.selectedSampleIndex) {
                    ForEach(viewModel.samples) { sample in
                        Text(sample.title).tag(sample.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.brand)

                HStack(spacing: Spacing.base) {
                    Button("加载到编辑器") {
                        withAnimation(.snappy) {
                            viewModel.loadSampleToContent()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brand)

                    Button("往返测试") {
                        viewModel.roundTripTest()
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.brand)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - 摘录编辑器

    private var contentEditorSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("摘录编辑器")

                RichTextEditor(
                    attributedText: $viewModel.contentText,
                    activeFormats: $viewModel.contentFormats,
                    highlightARGB: viewModel.selectedHighlightARGB
                )
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.item))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.item)
                        .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
                )

                activeFormatsDisplay(viewModel.contentFormats)
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - 高亮色板

    private var highlightColorSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("高亮色板")
                HighlightColorPicker(selectedARGB: $viewModel.selectedHighlightARGB)
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - 想法编辑器

    private var ideaEditorSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("想法编辑器")

                RichTextEditor(
                    attributedText: $viewModel.ideaText,
                    activeFormats: $viewModel.ideaFormats,
                    highlightARGB: viewModel.selectedHighlightARGB
                )
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.item))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.item)
                        .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
                )

                activeFormatsDisplay(viewModel.ideaFormats)
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - HTML 输出

    private var htmlOutputSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("HTML 序列化")

                HStack(spacing: Spacing.base) {
                    Button("序列化摘录") {
                        viewModel.serializeContent()
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.brand)

                    Button("序列化想法") {
                        viewModel.serializeIdea()
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.brand)
                }

                if !viewModel.contentHTML.isEmpty {
                    htmlBlock("摘录 HTML", viewModel.contentHTML)
                }

                if !viewModel.ideaHTML.isEmpty {
                    htmlBlock("想法 HTML", viewModel.ideaHTML)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - 往返测试

    private var roundTripSection: some View {
        Group {
            if let result = viewModel.roundTripResult {
                CardContainer {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        sectionHeader("往返测试结果")

                        switch result {
                        case .consistent:
                            Label("HTML 往返一致", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.brand)
                                .font(.headline)

                        case .inconsistent(let original, let roundTripped):
                            Label("HTML 往返不一致", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.headline)

                            htmlBlock("第一次序列化", original)
                            htmlBlock("第二次序列化", roundTripped)
                        }
                    }
                    .padding(Spacing.contentEdge)
                }
            }
        }
    }

    // MARK: - 辅助视图

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func activeFormatsDisplay(_ formats: Set<RichTextFormat>) -> some View {
        HStack(spacing: 6) {
            Text("激活格式:")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if formats.isEmpty {
                Text("无")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(formats), id: \.self) { format in
                    Text(formatName(format))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tagBackground, in: Capsule())
                }
            }
        }
    }

    private func htmlBlock(_ label: String, _ html: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(html)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(Spacing.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.windowBackground)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.item))
        }
    }

    private func formatName(_ format: RichTextFormat) -> String {
        switch format {
        case .bold: "B"
        case .italic: "I"
        case .underline: "U"
        case .strikethrough: "S"
        case .highlight: "H"
        case .bulletList: "Li"
        case .blockquote: "Q"
        case .link: "A"
        }
    }
}

#Preview {
    RichTextTestView()
        .tint(Color.brand)
}
