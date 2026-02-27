# Domain/
> L2 | 父级: /CLAUDE.md

仓储契约层与跨层领域模型。定义 Repository 协议与 ViewModel/Data 共享的数据结构。

## Models/

- `BookModels.swift`: BookItem、BookDetail、NoteExcerpt 书籍域展示模型
- `Tag.swift`: Tag、TagSection 标签域展示模型
- `NoteCategory.swift`: NoteCategory 枚举（书摘/相关/书评三分类）
- `RepositoryModels.swift`: NoteDetailPayload、BackupServerFormInput 仓储 IO 模型

## Repositories/

- `RepositoryProtocols.swift`: BookRepositoryProtocol、NoteRepositoryProtocol、BackupServerRepositoryProtocol、BackupRepositoryProtocol 四个仓储契约

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
