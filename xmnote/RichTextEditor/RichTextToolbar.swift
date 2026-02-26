import UIKit

/// 格式工具栏，挂载为 UITextView.inputAccessoryView
/// 水平滚动布局，包含格式按钮 + 撤销/重做 + 清除格式 + 收起键盘
final class RichTextToolbar: UIView {

    // MARK: - 回调

    private let onFormatAction: (RichTextFormat) -> Void
    private let onClearFormats: () -> Void
    private let onDismissKeyboard: () -> Void

    // MARK: - 按钮引用（用于更新激活状态）

    private var formatButtons: [RichTextFormat: UIButton] = [:]
    private var clearFormatsButton: UIButton!
    private var undoButton: UIButton!
    private var redoButton: UIButton!

    // MARK: - 关联的 textView（用于撤销/重做）

    weak var textView: UITextView?

    // MARK: - 初始化

    init(
        onFormatAction: @escaping (RichTextFormat) -> Void,
        onClearFormats: @escaping () -> Void,
        onDismissKeyboard: @escaping () -> Void
    ) {
        self.onFormatAction = onFormatAction
        self.onClearFormats = onClearFormats
        self.onDismissKeyboard = onDismissKeyboard
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        autoresizingMask = .flexibleWidth
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(onFormatAction:onClearFormats:onDismissKeyboard:)")
    }

    // MARK: - UI 构建

    private func setupUI() {
        backgroundColor = .secondarySystemBackground

        // 顶部分隔线
        let topBorder = UIView()
        topBorder.backgroundColor = .separator
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        // 滚动容器
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.spacing = 2
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            scrollView.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -4),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])

        // 撤销 / 重做
        undoButton = makeButton(systemName: "arrow.uturn.backward", action: #selector(undoTapped))
        redoButton = makeButton(systemName: "arrow.uturn.forward", action: #selector(redoTapped))
        stackView.addArrangedSubview(undoButton)
        stackView.addArrangedSubview(redoButton)
        stackView.addArrangedSubview(makeSeparator())

        // 字符级格式
        let boldBtn = makeFormatButton(format: .bold, systemName: "bold")
        let italicBtn = makeFormatButton(format: .italic, systemName: "italic")
        let underlineBtn = makeFormatButton(format: .underline, systemName: "underline")
        let strikethroughBtn = makeFormatButton(format: .strikethrough, systemName: "strikethrough")
        let highlightBtn = makeFormatButton(format: .highlight, systemName: "highlighter")
        stackView.addArrangedSubview(boldBtn)
        stackView.addArrangedSubview(italicBtn)
        stackView.addArrangedSubview(underlineBtn)
        stackView.addArrangedSubview(strikethroughBtn)
        stackView.addArrangedSubview(highlightBtn)
        stackView.addArrangedSubview(makeSeparator())

        // 段落级格式
        let bulletBtn = makeFormatButton(format: .bulletList, systemName: "list.bullet")
        let quoteBtn = makeFormatButton(format: .blockquote, systemName: "text.quote")
        stackView.addArrangedSubview(bulletBtn)
        stackView.addArrangedSubview(quoteBtn)
        stackView.addArrangedSubview(makeSeparator())

        // 链接
        let linkBtn = makeFormatButton(format: .link, systemName: "link")
        stackView.addArrangedSubview(linkBtn)
        stackView.addArrangedSubview(makeSeparator())

        // 清除格式
        let clearBtn = makeButton(systemName: "textformat", action: #selector(clearFormatsTapped))
        // 添加斜线表示"清除"
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        clearBtn.setImage(UIImage(systemName: "textformat", withConfiguration: config), for: .normal)
        clearFormatsButton = clearBtn
        stackView.addArrangedSubview(clearBtn)

        // 弹性空间
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(spacer)

        // 收起键盘
        let dismissBtn = makeButton(systemName: "keyboard.chevron.compact.down", action: #selector(dismissKeyboardTapped))
        stackView.addArrangedSubview(dismissBtn)
    }

    // MARK: - 按钮工厂

    private func makeButton(systemName: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.setImage(UIImage(systemName: systemName, withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40),
        ])
        return button
    }

    private func makeFormatButton(format: RichTextFormat, systemName: String) -> UIButton {
        let button = makeButton(systemName: systemName, action: #selector(formatButtonTapped(_:)))
        button.tag = formatTag(for: format)
        formatButtons[format] = button
        return button
    }

    private func makeSeparator() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 24),
        ])
        return view
    }

    // MARK: - 格式 ↔ Tag 映射

    private func formatTag(for format: RichTextFormat) -> Int {
        switch format {
        case .bold: return 100
        case .italic: return 101
        case .underline: return 102
        case .strikethrough: return 103
        case .highlight: return 104
        case .bulletList: return 105
        case .blockquote: return 106
        case .link: return 107
        }
    }

    private func format(for tag: Int) -> RichTextFormat? {
        switch tag {
        case 100: return .bold
        case 101: return .italic
        case 102: return .underline
        case 103: return .strikethrough
        case 104: return .highlight
        case 105: return .bulletList
        case 106: return .blockquote
        case 107: return .link
        default: return nil
        }
    }

    // MARK: - Actions

    @objc private func formatButtonTapped(_ sender: UIButton) {
        guard let fmt = format(for: sender.tag) else { return }
        onFormatAction(fmt)
    }

    @objc private func undoTapped() {
        textView?.undoManager?.undo()
    }

    @objc private func redoTapped() {
        textView?.undoManager?.redo()
    }

    @objc private func clearFormatsTapped() {
        onClearFormats()
    }

    @objc private func dismissKeyboardTapped() {
        onDismissKeyboard()
    }

    // MARK: - 状态更新

    /// 根据当前选区的格式集合更新按钮高亮
    func updateActiveFormats(_ formats: Set<RichTextFormat>) {
        let activeColor = UIColor.systemGreen
        let normalColor = UIColor.label

        for (format, button) in formatButtons {
            guard button.isEnabled else { continue }
            let isActive = formats.contains(format)
            button.tintColor = isActive ? activeColor : normalColor
            button.backgroundColor = isActive ? activeColor.withAlphaComponent(0.12) : .clear
            button.layer.cornerRadius = isActive ? 6 : 0
        }

        // 撤销/重做状态
        undoButton.isEnabled = textView?.undoManager?.canUndo ?? false
        redoButton.isEnabled = textView?.undoManager?.canRedo ?? false
        undoButton.tintColor = undoButton.isEnabled ? .label : .tertiaryLabel
        redoButton.tintColor = redoButton.isEnabled ? .label : .tertiaryLabel
    }

    /// 根据选区状态启用/禁用格式按钮
    func updateSelectionState(hasSelection: Bool) {
        let disabledColor = UIColor.tertiaryLabel
        let enabledColor = UIColor.label

        for (format, button) in formatButtons {
            // 段落级格式不需要选区也能操作（光标所在行）
            let needsSelection = (format != .bulletList && format != .blockquote)
            button.isEnabled = needsSelection ? hasSelection : true
            if button.isEnabled {
                // 恢复到可用态的基础视觉，激活态由 updateActiveFormats 覆盖
                button.tintColor = enabledColor
            } else {
                button.tintColor = disabledColor
                button.backgroundColor = .clear
                button.layer.cornerRadius = 0
            }
        }

        clearFormatsButton.isEnabled = hasSelection
        clearFormatsButton.tintColor = hasSelection ? .label : disabledColor
    }
}
