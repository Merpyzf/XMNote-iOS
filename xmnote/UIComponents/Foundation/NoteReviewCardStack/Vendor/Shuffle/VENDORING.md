# Shuffle Vendoring

- Upstream: https://github.com/mac-gallagher/Shuffle
- Pinned version: `v0.5.0`
- Pinned commit: `df246b9cd6b8b5e021b23c80706b4a4571785c1b`
- License: MIT, retained in `LICENSE`

Local changes:

- Added XMNote L3 headers to Swift source files.
- Prefixed upstream public/core symbols with `XMNoteReview`.
- Exposed configurable visible count, threshold, scale, translation, and scroll arbitration needed by `NoteReviewCardStack`.
- Kept the SwiftUI-facing API outside the vendored source.
