# BigUIPaging Vendoring

- Upstream: https://github.com/notsobigcompany/BigUIPaging
- Baseline: `master` commit `d546c84`
- License: MIT, copyright 2023 NOT SO BIG TECH LIMITED.
- Scope: only the PageView core, style protocol, navigation direction/action, environment plumbing, and size measurement helper are vendored for the note review card deck.
- Note: upstream `CardDeckPageViewStyle` / `.cardDeck` is not vendored or used; XMNote implements its own `PageViewStyle` for the note review deck on top of the vendored core.
- Local changes:
  - Removed the original `ValueStore` cache so dynamic next/previous closures always read the latest collection state after pagination or refresh.
  - Changed `PageViewStyleConfiguration.Value` to store `AnyHashable`, fixing equality for different values that share the same hash value.
  - Updated SwiftUI change observation to the modern two-argument `onChange` form.
  - Omitted examples, PageIndicator, and platform UIPageViewController/macOS styles because the note review deck uses a custom SwiftUI card style.

MIT License

Copyright (c) 2023 NOT SO BIG TECH LIMITED

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
