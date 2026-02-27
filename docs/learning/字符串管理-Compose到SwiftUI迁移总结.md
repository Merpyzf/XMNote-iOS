# 字符串管理迁移总结（Android Compose → SwiftUI）

## 1. 本次 iOS 关键知识点

- **String Catalog 机制**
  `Localizable.xcstrings` 是 Xcode 15+ 引入的 JSON 格式本地化方案，替代传统 `.strings` / `.stringsdict`。Xcode 编译时自动扫描代码中的字符串字面量，提取到 Catalog；开发者在 Catalog 中按语言填充翻译。一个文件管理所有语言，不再需要 `en.lproj` / `zh-Hans.lproj` 目录散落。

- **SwiftUI 隐式本地化（核心认知差异）**
  `Text("书籍")` 中的字符串字面量自动被视为 `LocalizedStringKey`，SwiftUI 在渲染时查找 Catalog 中的翻译。开发者无需显式调用任何本地化函数——写中文原文即可，Xcode 自动提取。这是与 Android `stringResource(R.string.key)` 最大的区别。

- **显式本地化 `String(localized:)`**
  用于非 SwiftUI 上下文：ViewModel 日志、UIKit 桥接、Alert 标题拼接等。等价于旧版 `NSLocalizedString`，但语法更简洁。仅在 `Text()` 之外需要本地化字符串时使用。

- **参数化字符串**
  `Text("\(count) 条书摘")` 自动生成 `%lld 条书摘` 格式的 Catalog 条目。Swift 字符串插值直接映射为格式化占位符，支持复数规则（`.stringsdict` 语义内嵌于 xcstrings）。

- **String Catalog 的 state 字段**
  三种状态追踪翻译进度：`translated`（已翻译）、`needs_review`（待审核）、`new`（新提取，未翻译）。

- **本项目现状**
  sourceLanguage 为 `zh-Hans`，含 `en` 占位。en 翻译全部为 `needs_review` 状态（空值），100+ 条目。代码中 `Text("中文")` 隐式本地化与 `String(localized:)` 显式本地化混合使用。

## 2. Android Compose 对照思路

| Android | iOS | 对照说明 |
|---|---|---|
| `res/values/strings.xml` | `Localizable.xcstrings` | 字符串资源文件；Android 按目录分语言，iOS 单文件内嵌所有语言 |
| `@string/key`（XML）/ `stringResource(R.string.key)`（Compose） | `Text("中文原文")` 隐式查找 | Android 必须显式引用资源 ID，SwiftUI 字面量即 key |
| `getString(R.string.key)` | `String(localized: "中文原文")` | 非 UI 上下文获取本地化字符串 |
| `values-en/strings.xml` | xcstrings 内 `en` 节点 | 多语言：Android 多目录，iOS 单文件多节点 |
| `<plurals>` / `quantityStringResource` | xcstrings 内置 plural 规则 | 复数处理：Android 需单独 `<plurals>` 块，iOS 在 Catalog 条目内配置 |
| `buildAnnotatedString` | `AttributedString` + `Text` | 富文本拼接 |
| Gradle `resValue` | Build Settings / Scheme 环境变量 | 构建时注入字符串 |
| 手动维护 key 列表 | Xcode 自动扫描提取 | iOS 无需手动注册，编译时自动发现 |

## 3. 可运行示例（最小骨架）

```swift
import SwiftUI

// ============================================================
// MARK: - ViewModel（非 UI 上下文使用 String(localized:)）
// ============================================================

@Observable
class BookShelfViewModel {
    var books: [String] = ["人类简史", "三体", "小王子"]

    /// 非 SwiftUI 上下文：用 String(localized:) 显式本地化
    var summaryText: String {
        String(localized: "\(books.count) 本书籍")
    }

    func deleteConfirmMessage(for name: String) -> String {
        String(localized: "确定删除「\(name)」吗？")
    }
}

// ============================================================
// MARK: - View（SwiftUI 隐式本地化）
// ============================================================

struct BookShelfView: View {
    @State private var vm = BookShelfViewModel()
    @State private var showAlert = false
    @State private var pendingDelete: String?

    var body: some View {
        NavigationStack {
            List {
                // ① 隐式本地化：字面量自动作为 LocalizedStringKey
                Section("我的书架") {
                    ForEach(vm.books, id: \.self) { book in
                        bookRow(book)
                    }
                }

                // ② 参数化字符串：插值自动生成 %lld 格式条目
                Section {
                    Text("\(vm.books.count) 本书籍")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("书籍")  // 隐式本地化
            .alert("删除确认", isPresented: $showAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let name = pendingDelete {
                        vm.books.removeAll { $0 == name }
                    }
                }
            } message: {
                // ③ 显式本地化：Alert message 接受 Text，仍可用字面量
                if let name = pendingDelete {
                    Text("确定删除「\(name)」吗？")
                }
            }
        }
    }

    private func bookRow(_ name: String) -> some View {
        HStack {
            Text(name)  // 普通变量不触发本地化查找
            Spacer()
            Button("删除") {  // "删除" 隐式本地化
                pendingDelete = name
                showAlert = true
            }
            .foregroundStyle(.red)
        }
    }
}

#Preview { BookShelfView() }
```

## 4. 迁移经验

- **最大认知跃迁：隐式 vs 显式**
  Android 必须通过 `R.string.key` 显式引用资源 ID，SwiftUI 用字面量即可。初次迁移时最容易犯的错误是习惯性地为每个字符串定义 key——在 iOS 中这是多余的，`Text("中文原文")` 本身就是 key。

- **String Catalog 自动提取 = 不需要手动维护 key 列表**
  Android 开发者习惯先在 `strings.xml` 注册 key 再引用。iOS 反过来：先在代码里写字面量，Xcode 编译时自动发现并添加到 Catalog。忘记注册不会编译失败，只是 Catalog 里多一条 `new` 状态的条目。

- **参数化字符串直接用插值**
  Android 需要 `getString(R.string.key, count)` + `<xliff:g>` 占位符。iOS 直接 `Text("\(count) 条书摘")`，Xcode 自动生成 `%lld 条书摘` 格式条目。心智负担大幅降低。

- **`String(localized:)` 仅在非 SwiftUI 上下文使用**
  SwiftUI 视图内优先用字面量（隐式本地化）。只有 ViewModel、Service、UIKit 桥接等拿不到 `LocalizedStringKey` 的地方才需要 `String(localized:)`。过度使用 `String(localized:)` 反而破坏 SwiftUI 的自动追踪机制。

- **变量传入 `Text()` 不会触发本地化查找**
  `let name = "书籍"; Text(name)` 不会查找翻译——`name` 是 `String` 类型，不是 `LocalizedStringKey`。只有字面量才触发隐式本地化。需要对变量本地化时，用 `Text(LocalizedStringKey(name))` 或在上游用 `String(localized:)` 转换。

- **xcstrings 文件冲突处理**
  多人协作时 `Localizable.xcstrings` 是 JSON，合并冲突比 Android 的 XML 更容易处理。但条目顺序由 Xcode 控制，不要手动排序。
