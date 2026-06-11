# SwiftUI Environment Patterns

Use this reference when code reads or writes `@Environment`, `EnvironmentValues`, `FocusedValue`, `FocusedValues`, or custom environment keys.

## Core Rule

Keep environment values stable, narrow, and data-oriented. Environment writes propagate through a subtree, so broad or frequently-changing values can invalidate more UI than the feature needs.

## Custom Environment Values

Use `@Entry` for new custom environment, focused, transaction, or container values when the deployment/toolchain supports it.

```swift
extension EnvironmentValues {
    @Entry var accentTheme: AccentTheme = .default
}
```

Prefer small value types or stable model references. Avoid storing large value-type payloads in the environment when only a few descendants need one field.

## Do Not Store Closures In Custom Keys

Do not put closure or function values in custom environment or focused values. SwiftUI cannot reliably compare function values, so readers can re-evaluate even when the behavior is effectively unchanged.

```swift
// Avoid
extension EnvironmentValues {
    @Entry var saveAction: () -> Void = {}
}

// Prefer
@MainActor
@Observable
final class SaveController {
    func save() {}
}

extension EnvironmentValues {
    @Entry var saveController: SaveController?
}
```

Framework-provided action values such as `dismiss`, `openURL`, and `refresh` are designed for this use and are not violations.

## Scope Frequently-Changing Values

Avoid placing geometry, timer ticks, scroll offsets, progress frames, or rapidly changing transient values high in the environment. Keep them local, pass the specific value to the immediate view that needs it, or gate updates by thresholds before assignment.

## Review Checklist

- Custom keys use `@Entry` where available.
- Custom environment/focused values do not store closures.
- Broad environment values are stable or low-frequency.
- High-frequency state is local, narrowly passed, or threshold-gated.
- Framework-provided action environment values are left intact.
