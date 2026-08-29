/**
 * [INPUT]: 依赖 UIComponents/Controls/Search 的 XMSystemSearchBar
 * [OUTPUT]: 保留 BookPickerSystemSearchBar 旧名兼容别名，让现有选书调用无需同步改名
 * [POS]: Book 模块过渡兼容层；真实 UISearchBar owner 已上移至设计系统
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

typealias BookPickerSystemSearchBar = XMSystemSearchBar
