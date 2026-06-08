# 字符串管理迁移总结（Android Compose → SwiftUI）

## 1. 本次问题复盘：为什么会出现 `Books`

这次现象是全局搜索范围栏里只有“书籍”显示成英文 `Books`，而同一行的“全部 / 书摘 / 相关”仍是中文。第一眼像是 UI 层写错了文案，但代码链路显示问题不在控件渲染，而在运行时选择到了错误的本地化资源。

真实调用链如下：

```swift
GlobalSearchScope.book.title
    -> GlobalSearchCategory.book.title
    -> String(localized: "书籍")
    -> XMScopeSelectorItem.title
    -> Text(item.title)
```

`Text(item.title)` 里的 `item.title` 是普通 `String`，不是 SwiftUI 字面量产生的 `LocalizedStringKey`。因此它显示什么完全取决于上游 `String(localized: "书籍")` 已经解析出的值。

根因分三层：

- 工程曾声明 `developmentRegion = en`，`knownRegions` 也只包含 `en` / `Base`，构建产物里实际只有 `en.lproj`。
- `Localizable.xcstrings` 的 `sourceLanguage` 是 `zh-Hans`，但 `"书籍"` 曾存在残缺的 `en` 翻译值 `Books`。
- 模拟器语言虽然是 `zh-Hans-CN`，但 Bundle 只能在包内已有本地化资源中选择；当包里只有英文资源时，中文用户环境也会命中英文资源。

修复原则不是“让中文 key 在英文资源缺失时回退”，而是让中文成为真实开发语言和真实可用本地化。当前项目应保持：

- `CFBundleDevelopmentRegion` / Xcode `developmentRegion` 为 `zh-Hans`。
- `Localizable.xcstrings` 的 `sourceLanguage` 为 `zh-Hans`。
- 不保留半截英文翻译；未来要上线英文时，必须一次性补齐完整 `en` 资源后再把 `en` 加回正式支持区域。
- 通过 `zh-Hans.lproj/InfoPlist.strings` 等真实资源让 app bundle 明确携带中文本地化目录。

## 2. iOS 字符串与国际化机制

iOS 运行时不会推测界面“应该显示中文”。它只会根据 app bundle 里实际包含的本地化目录和用户语言偏好选择资源。Apple 的 `Bundle.localizations` 表示包内可用语言，`Bundle.preferredLocalizations` 表示按用户偏好和包内可用语言计算出的实际优先语言，`Bundle.developmentLocalization` 来自 `CFBundleDevelopmentRegion`。

Xcode 15 之后推荐用 String Catalog 管理用户可见文案。`Localizable.xcstrings` 是源文件，构建时会按翻译语言生成对应 `.lproj` 资源。`sourceLanguage` 是开发源语言，不等于“所有运行时一定会生成这个语言的 `Localizable.strings`”。如果项目需要 bundle 明确声明中文可用，仍需要确保最终 app 包里存在 `zh-Hans.lproj`，例如本项目使用 `InfoPlist.strings` 作为中文资源锚点。

常见资源职责：

| 资源 | 作用 | XMNote 约束 |
|---|---|---|
| `Localizable.xcstrings` | 管理普通 UI 文案、按钮、空态、错误态、无障碍文案 | 源语言固定为 `zh-Hans` |
| `InfoPlist.strings` | 本地化 app 名称、权限说明等 Info.plist 用户可见字段 | 中文版本必须有 `zh-Hans.lproj` |
| `.lproj` 目录 | app bundle 运行时可选择的本地化资源目录 | 不提交残缺英文目录 |
| `CFBundleDevelopmentRegion` | 开发语言与兜底语言 | 中文优先版本为 `zh-Hans` |

官方依据：

- Apple [Localization](https://developer.apple.com/documentation/xcode/localization/) 文档说明 Xcode 15+ 推荐 String Catalog。
- Apple [Localizing and varying text with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) 文档说明 String Catalog 的翻译与变体管理方式。
- Apple [LocalizedStringKey](https://developer.apple.com/documentation/swiftui/localizedstringkey) 文档说明 SwiftUI 字面量会作为本地化 key 查找。
- Apple [String(localized:)](https://developer.apple.com/documentation/swift/string/init%28localized:%29) 文档说明它会从 String Catalog 或 `.strings` 文件查找本地化值。
- Apple [Bundle preferredLocalizations](https://developer.apple.com/documentation/foundation/bundle/preferredlocalizations) 文档说明运行时只会从 bundle 已包含的本地化中选择。

## 3. SwiftUI 常见写法与边界

SwiftUI 最重要的差异是“字符串字面量”和“普通 String 变量”语义不同：

```swift
Text("搜索")                  // 字面量，走 LocalizedStringKey
Button("取消") { }            // 字面量，走 LocalizedStringKey
Text(item.title)              // 普通 String，直接显示变量值
Text(verbatim: book.title)    // 明确按原文显示，不做本地化
```

推荐规则：

- `Text("搜索")`、`Button("删除")`、`.navigationTitle("书籍")` 这类固定用户可见字面量，优先让 SwiftUI 隐式本地化。
- enum、model、view model、UIKit 桥接、无障碍值等需要普通 `String` 的地方，用 `String(localized:)`。
- 用户输入、数据库内容、远端返回内容、书名、作者、ISBN、代码标识、SF Symbols 名称，用 `Text(verbatim:)` 或普通 `String` 直出，不能进入本地化资源。
- 数量和日期优先使用系统格式化能力，例如 `NumberFormatter.localizedString`、`Date.FormatStyle`。纯数字徽标可用 `Text(verbatim:)`，避免被当成本地化 key。
- `Text(LocalizedStringKey(value))` 只适合明确知道 `value` 是本地化 key 的少数场景；业务数据不要这样处理。

`String(localized:)` 适合这种领域模型标题：

```swift
enum GlobalSearchCategory {
    case book
    case note

    var title: String {
        switch self {
        case .book:
            String(localized: "书籍")
        case .note:
            String(localized: "书摘")
        }
    }
}
```

控件接收普通 `String` 时，要由调用方决定是否已经本地化：

```swift
XMScopeSelectorItem(
    id: .book,
    title: GlobalSearchCategory.book.title
)
```

如果直接写 `title: "书籍"`，再在控件内部 `Text(item.title)`，它不会自动按字面量重新走 `LocalizedStringKey`。这类组件边界需要在文档或类型命名中保持清楚。

## 4. 用户可见文案如何管理

需要资源化的内容：

- 页面标题、Tab 标题、按钮标题、菜单项、Sheet 标题。
- 空态、错误态、加载态、确认弹窗、Toast 或系统 Alert 文案。
- 无障碍标签、无障碍值、语音提示。
- Info.plist 中会显示给用户的 app 名称、权限说明。
- 固定业务分类名，例如“全部 / 书籍 / 书摘 / 相关”。

不应资源化的内容：

- 用户创建或输入的内容。
- 数据库、网络、第三方服务返回的业务数据。
- 书名、作者、出版社、ISBN、标签原值。
- 调试日志、断言文本、测试页临时说明。
- 代码常量、接口字段名、SF Symbols 名称、图片资源名。

项目规范：

- 固定文案优先写中文源文案，让 `Localizable.xcstrings` 以中文作为 source language 管理。
- 不新增空的 `en` localization；英文版必须作为独立任务补齐完整资源。
- 生产代码中出现普通 `String` 参数承载 UI 文案时，调用方必须传入已经本地化的值，或组件 API 明确改成 `LocalizedStringKey` / `LocalizedStringResource`。
- 不用英文 key 加中文 value 的 Android 风格迁移方式，除非整个项目切换到 key-based 本地化策略并统一治理。

## 5. Android Compose 对照思路

| Android | iOS | 对照说明 |
|---|---|---|
| `res/values/strings.xml` | `Localizable.xcstrings` | 字符串资源入口；Android 多目录，iOS String Catalog 单文件管理多语言 |
| `stringResource(R.string.key)` | `Text("中文原文")` | SwiftUI 字面量可直接作为本地化 key |
| `context.getString(...)` | `String(localized:)` | 非 SwiftUI 上下文取本地化普通字符串 |
| `values-en/strings.xml` | `en` localization | 英文必须完整，不保留半截占位 |
| `<plurals>` | String Catalog variation | 复数、设备差异等在 Catalog 中配置 |
| `AnnotatedString` | `AttributedString` + `Text` | 富文本本地化需要额外设计占位与拼接边界 |

迁移心智差异：

- Android 常先定义资源 key，再在代码中引用；SwiftUI 常先写源语言字面量，再由 Xcode 提取。
- Android 编译期能发现缺失 `R.string`；SwiftUI 缺失翻译通常运行时回退到 key，所以更依赖资源审查。
- iOS 的 Bundle 语言选择取决于最终 app 包内的 `.lproj`，不能只看源码里的 `sourceLanguage`。

## 6. 最小示例

```swift
import SwiftUI

@Observable
final class SearchTitleModel {
    var categoryTitle: String {
        String(localized: "书籍")
    }

    func resultCountText(_ count: Int) -> String {
        String(localized: "\(count) 项")
    }
}

struct SearchTitleExampleView: View {
    @State private var model = SearchTitleModel()
    let bookName: String
    let count: Int

    var body: some View {
        VStack(alignment: .leading) {
            Text("搜索")
            Text(model.categoryTitle)
            Text(verbatim: bookName)
            Text(verbatim: NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal))
        }
        .accessibilityLabel(String(localized: "搜索范围"))
    }
}
```

这段代码里，“搜索”“书籍”“搜索范围”是固定 UI 文案，需要资源化；`bookName` 是业务数据，必须保留原文；`count` 是数字展示，优先格式化后按原文显示。
