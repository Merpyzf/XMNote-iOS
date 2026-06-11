# SwiftUI Localization Patterns

Use this reference when adding or reviewing user-facing text, formatting, or bidirectional layout in SwiftUI.

## Preserve Localization Context

Pass string literals directly to SwiftUI text-bearing views when they are user-facing. Avoid resolving them early with `NSLocalizedString`, `String(localized:)`, or manual wrappers at the call site unless the surrounding architecture requires it.

```swift
// Prefer
Text("Start reading")
Button("Save") { save() }

// Use for debug or intentionally nonlocalized literals
Text(verbatim: "Build: \(buildNumber)")
```

When a non-view model carries reusable user-facing text, prefer `LocalizedStringResource` over plain `String` so localization remains deferred until presentation.

```swift
struct EmptyStateCopy {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
}
```

## Interpolation, Not Sentence Assembly

Use interpolation inside one localized string. Do not concatenate localized fragments to form a sentence; grammar and word order vary by language.

```swift
Text("Created by \(authorName)")
```

## Locale-Aware Formatting

Use Swift format styles for dates, numbers, currency, measurements, and lists. They adapt to the user's locale and preserve localization for the surrounding sentence.

```swift
Text(readDate, format: .dateTime.year().month().day())
Text(price, format: .currency(code: currencyCode))
Text("Books: \(bookTitles.formatted())")
```

If a formatter is unavoidable, use localized templates instead of hardcoded date formats.

## Casing and Direction

Prefer authoring the intended case in the localized string. Runtime transforms such as `.textCase(.uppercase)` can force unsuitable casing across languages.

Use `leading` and `trailing` instead of `left` and `right` for layout and alignment so right-to-left locales can mirror correctly.

## Review Checklist

- User-facing literals stay localizable.
- Debug/nonlocalized text uses `Text(verbatim:)`.
- Reusable non-view copy uses `LocalizedStringResource` when practical.
- Sentences are not assembled by concatenating localized fragments.
- Dates, numbers, currencies, and lists use format styles.
- Layout uses leading/trailing for bidirectional support.
