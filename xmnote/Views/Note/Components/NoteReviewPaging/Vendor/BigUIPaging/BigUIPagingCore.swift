/**
 * [INPUT]: Vendored BigUIPaging PageView 核心源码，依赖 SwiftUI 环境、Binding 与 PreferenceKey
 * [OUTPUT]: 对外提供 PageView、PageViewStyle、PageViewStyleConfiguration 与分页导航环境
 * [POS]: Views/Note/Components/NoteReviewPaging 的源码级第三方基座，仅由书摘回顾分页卡组间接使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 将当前页值解析为相邻页值的轻量帮助器，刻意不缓存闭包结果以适配动态分页数据。
struct PageViewAdjacencyResolver<SelectionValue: Hashable> {
    let next: (SelectionValue) -> SelectionValue?
    let previous: (SelectionValue) -> SelectionValue?

    /// 返回指定值之后的下一页值，每次都透传给最新闭包。
    func next(after value: SelectionValue) -> SelectionValue? {
        next(value)
    }

    /// 返回指定值之前的上一页值，每次都透传给最新闭包。
    func previous(before value: SelectionValue) -> SelectionValue? {
        previous(value)
    }
}

/// 供自定义分页样式读取当前选中值、相邻值与页面内容的配置对象。
struct PageViewStyleConfiguration {
    /// 对任意 Hashable 页值做类型擦除，保持真实值相等语义而不是只比较 hashValue。
    struct Value: Hashable {
        let wrappedValue: AnyHashable

        init(_ wrappedValue: some Hashable) {
            self.wrappedValue = AnyHashable(wrappedValue)
        }
    }

    /// 对任意页面 View 做类型擦除，供 style 在统一数组中渲染。
    struct Page: View {
        let wrappedView: AnyView

        init<V: View>(_ view: V) {
            wrappedView = AnyView(view)
        }

        var body: some View {
            wrappedView
        }
    }

    var selection: Binding<Value>
    let next: (Value) -> Value?
    let previous: (Value) -> Value?
    let content: (Value) -> Page
}

extension PageViewStyleConfiguration {
    /// 返回目标值前后有限数量的页值，并给出目标值在结果数组中的索引。
    func values(surrounding value: Value, limit: Int = 3) -> ([Value], Int) {
        let resolvedLimit = max(0, limit)
        var currentValue = value
        var previousValues = [Value]()
        while let previousValue = previous(currentValue), previousValues.count < resolvedLimit {
            previousValues.insert(previousValue, at: 0)
            currentValue = previousValue
        }

        currentValue = value
        var nextValues = [value]
        while let nextValue = next(currentValue), nextValues.count <= resolvedLimit {
            nextValues.append(nextValue)
            currentValue = nextValue
        }

        return (previousValues + nextValues, previousValues.count)
    }

    var canNavigate: PageViewDirection {
        var directions = PageViewDirection()
        if next(selection.wrappedValue) != nil {
            directions.insert(.forwards)
        }
        if previous(selection.wrappedValue) != nil {
            directions.insert(.backwards)
        }
        return directions
    }

    func navigateAction(_ id: UUID) -> PageViewNavigateAction {
        PageViewNavigateAction(id: id) { direction in
            switch direction {
            case .forwards:
                if let next = next(selection.wrappedValue) {
                    selection.wrappedValue = next
                }
            case .backwards:
                if let previous = previous(selection.wrappedValue) {
                    selection.wrappedValue = previous
                }
            default:
                break
            }
        }
    }
}

/// 分页视图支持的前进/后退方向集合。
struct PageViewDirection: OptionSet, Hashable {
    var rawValue: Int

    init(rawValue: Int = 0) {
        self.rawValue = rawValue
    }

    static let forwards = PageViewDirection(rawValue: 1 << 1)
    static let backwards = PageViewDirection(rawValue: 1 << 2)
}

/// 环境中的分页导航动作，可由外层控制件触发 PageView 选中值变化。
struct PageViewNavigateAction: Equatable {
    static let `default` = PageViewNavigateAction(id: nil) { _ in }

    let id: UUID?
    let handler: (PageViewDirection) -> Void

    func callAsFunction(_ direction: PageViewDirection) {
        handler(direction)
    }

    static func == (lhs: PageViewNavigateAction, rhs: PageViewNavigateAction) -> Bool {
        lhs.id == rhs.id
    }
}

/// PageView 的样式协议；样式负责决定页面布局、手势与转场。
protocol PageViewStyle: DynamicProperty {
    associatedtype Body: View
    typealias Configuration = PageViewStyleConfiguration

    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// 默认只展示当前页、不提供手势的基础样式。
struct PlainPageViewStyle: PageViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content(configuration.selection.wrappedValue)
    }
}

extension PageViewStyle where Self == PlainPageViewStyle {
    static var plain: PlainPageViewStyle {
        PlainPageViewStyle()
    }
}

private struct ConcretePageViewStyle<Style: PageViewStyle>: View {
    let configuration: PageViewStyleConfiguration
    let style: Style

    var body: some View {
        style.makeBody(configuration: configuration)
    }
}

extension PageViewStyle {
    func makeConcreteView(_ configuration: Configuration) -> some View {
        ConcretePageViewStyle(configuration: configuration, style: self)
    }
}

/// 通过 selection binding 与 next/previous 闭包管理相关页面导航的 SwiftUI 容器。
struct PageView<SelectionValue: Hashable, Page: View>: View {
    @Binding var selection: SelectionValue
    let resolver: PageViewAdjacencyResolver<SelectionValue>
    @ViewBuilder let pageContent: (SelectionValue) -> Page

    @Environment(\.pageViewStyle) private var style
    @State private var id = UUID()

    /// 使用动态 next/previous 闭包创建分页容器；闭包会在每次 View 更新后重新参与解析。
    init(
        selection: Binding<SelectionValue>,
        next: @escaping (SelectionValue) -> SelectionValue?,
        previous: @escaping (SelectionValue) -> SelectionValue?,
        @ViewBuilder content: @escaping (SelectionValue) -> Page
    ) {
        _selection = selection
        resolver = PageViewAdjacencyResolver(next: next, previous: previous)
        pageContent = content
    }

    var body: some View {
        AnyView(style.makeConcreteView(configuration))
            .environment(\.navigatePageView, configuration.navigateAction(id))
            .preference(key: PageViewCanNavigatePreference.self, value: configuration.canNavigate)
            .preference(key: PageViewNavigateActionPreference.self, value: configuration.navigateAction(id))
    }
}

extension PageView {
    /// 使用 RandomAccessCollection 的 ForEach 数据源创建分页容器。
    init<Data>(
        selection: Binding<SelectionValue>,
        content: () -> ForEach<Data, Data.Element, Page>
    ) where Data: RandomAccessCollection, SelectionValue == Data.Element {
        let content = content()
        let data = content.data
        let page = content.content
        self.init(selection: selection) { value in
            guard let index = data.firstIndex(of: value) else { return nil }
            let next = data.index(after: index)
            return data.indices.contains(next) ? data[next] : nil
        } previous: { value in
            guard let index = data.firstIndex(of: value), index != data.startIndex else { return nil }
            return data[data.index(before: index)]
        } content: { value in
            page(value)
        }
    }

    /// 使用 Identifiable 集合的 ForEach 数据源创建分页容器。
    init<Data>(
        selection: Binding<SelectionValue>,
        content: () -> ForEach<Data, Data.Element.ID, Page>
    ) where Data: RandomAccessCollection, Data.Element: Identifiable, SelectionValue == Data.Element.ID {
        let content = content()
        let data = content.data
        let page = content.content
        self.init(selection: selection) { id in
            guard let index = data.firstIndex(where: { $0.id == id }) else { return nil }
            let next = data.index(after: index)
            return data.indices.contains(next) ? data[next].id : nil
        } previous: { id in
            guard let index = data.firstIndex(where: { $0.id == id }), index != data.startIndex else { return nil }
            return data[data.index(before: index)].id
        } content: { id in
            let value = data.first { $0.id == id } ?? data[data.startIndex]
            page(value)
        }
    }

    private var configuration: PageViewStyleConfiguration {
        PageViewStyleConfiguration(selection: configurationSelection) { value in
            guard let selectionValue = value.wrappedValue.base as? SelectionValue,
                  let nextValue = resolver.next(after: selectionValue)
            else { return nil }
            return PageViewStyleConfiguration.Value(nextValue)
        } previous: { value in
            guard let selectionValue = value.wrappedValue.base as? SelectionValue,
                  let previousValue = resolver.previous(before: selectionValue)
            else { return nil }
            return PageViewStyleConfiguration.Value(previousValue)
        } content: { value in
            guard let selectionValue = value.wrappedValue.base as? SelectionValue else {
                return PageViewStyleConfiguration.Page(EmptyView())
            }
            return PageViewStyleConfiguration.Page(pageContent(selectionValue))
        }
    }

    private var configurationSelection: Binding<PageViewStyleConfiguration.Value> {
        Binding {
            PageViewStyleConfiguration.Value(selection)
        } set: { newValue in
            if let value = newValue.wrappedValue.base as? SelectionValue {
                selection = value
            }
        }
    }
}

extension View {
    /// 设置当前层级内 PageView 使用的样式。
    func pageViewStyle<S: PageViewStyle>(_ style: S) -> some View {
        environment(\.pageViewStyle, style)
    }

    /// 将 PageView 的导航能力透传到环境中，供外部按钮读取。
    func pageViewEnvironment() -> some View {
        modifier(PageViewEnvironmentModifier())
    }

    /// 读取当前 View 的布局尺寸并写入 binding。
    func measure(_ size: Binding<CGSize>) -> some View {
        background {
            GeometryReader { reader in
                Color.clear.preference(key: ViewSizePreferenceKey.self, value: reader.size)
            }
        }
        .onPreferenceChange(ViewSizePreferenceKey.self) { value in
            size.wrappedValue = value ?? .zero
        }
    }
}

private struct ViewSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize?

    static func reduce(value: inout CGSize?, nextValue: () -> CGSize?) {
        value = nextValue() ?? value
    }
}

private struct PageViewCanNavigatePreference: PreferenceKey {
    static var defaultValue = PageViewDirection()

    static func reduce(value: inout PageViewDirection, nextValue: () -> PageViewDirection) {
        value.formUnion(nextValue())
    }
}

private struct PageViewNavigateActionPreference: PreferenceKey {
    static var defaultValue: PageViewNavigateAction?

    static func reduce(value: inout PageViewNavigateAction?, nextValue: () -> PageViewNavigateAction?) {
        value = nextValue() ?? value
    }
}

private struct PageViewEnvironmentModifier: ViewModifier {
    @State private var canNavigate = PageViewDirection()
    @State private var navigate: PageViewNavigateAction?

    func body(content: Content) -> some View {
        content
            .environment(\.canNavigatePageView, canNavigate)
            .environment(\.navigatePageView, navigate ?? .default)
            .onPreferenceChange(PageViewCanNavigatePreference.self) { value in
                canNavigate = value
            }
            .onPreferenceChange(PageViewNavigateActionPreference.self) { value in
                navigate = value
            }
    }
}

private extension EnvironmentValues {
    var pageViewStyle: any PageViewStyle {
        get { self[PageViewStyleKey.self] }
        set { self[PageViewStyleKey.self] = newValue }
    }

    var navigatePageView: PageViewNavigateAction {
        get { self[PageViewNavigateActionKey.self] }
        set { self[PageViewNavigateActionKey.self] = newValue }
    }

    var canNavigatePageView: PageViewDirection {
        get { self[PageViewCanNavigateKey.self] }
        set { self[PageViewCanNavigateKey.self] = newValue }
    }
}

private struct PageViewStyleKey: EnvironmentKey {
    static let defaultValue: any PageViewStyle = PlainPageViewStyle()
}

private struct PageViewNavigateActionKey: EnvironmentKey {
    static let defaultValue: PageViewNavigateAction = .default
}

private struct PageViewCanNavigateKey: EnvironmentKey {
    static let defaultValue = PageViewDirection()
}
