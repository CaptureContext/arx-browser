# Third-party notices

Arx itself is licensed under the GNU General Public License, version 3 ([LICENSE](LICENSE)). Arx includes the third-party material below. Each licence also travels with the material itself, and the texts this file refers to are in [Distribution/Licenses](Distribution/Licenses). The app shows this file under About Arx → Credits (`make credits` regenerates `Containers/macOS/Credits.rtf` from it).

## Browser engine

Arx's engine is the Helium browser for macOS, built from source with Arx's own patches (`Scripts/engine/`) into `Arx Framework.framework`. The pinned versions are in `Packages/engine/engine.lock.json`: helium-macos `da5fcc2`, Helium `a2d96a7`, Chromium 157.0.8103.78.

- **Helium** (<https://github.com/imputnet/helium>, <https://github.com/imputnet/helium-macos>) by imput. Helium's own code and patches are licensed under the GNU General Public License, version 3. Helium's `LICENSE` and `LICENSE.ungoogled_chromium` files from both pinned repositories are kept unchanged in [Packages/engine/Licenses](Packages/engine/Licenses).
- **ungoogled-chromium** (<https://github.com/ungoogled-software/ungoogled-chromium>). Code Helium takes unchanged from ungoogled-chromium stays under the BSD 3-Clause License: [Distribution/Licenses/ungoogled-chromium.txt](Distribution/Licenses/ungoogled-chromium.txt).
- **Chromium** (<https://www.chromium.org>), Copyright The Chromium Authors, under the BSD 3-Clause License: [Distribution/Licenses/chromium.txt](Distribution/Licenses/chromium.txt). `Packages/engine/Sources/ChromiumBootstrap/Upstream/` carries Chromium source with the same licence.
- **Chromium's third-party components.** Chromium bundles several hundred libraries under their own licences (BSD, MIT, Apache-2.0, LGPL, MPL and others). The engine build compiles their full list, with every licence text, into Chromium's `chrome://credits` page.

## Swift packages

These packages are compiled into Arx or its `ArxMCP` helper, except swift-snapshot-testing (tests), swift-syntax and swift-macro-toolkit (macros, used while compiling) and package-resources-cli (code generation), which aren't shipped. Versions come from the `Package.resolved` files; "fork" means a Git submodule under `Forks/`.

MIT-licensed packages are under the MIT License ([Distribution/Licenses/MIT.txt](Distribution/Licenses/MIT.txt)) with the copyright line shown. Apache-2.0 packages are under the Apache License, Version 2.0 ([Distribution/Licenses/Apache-2.0.txt](Distribution/Licenses/Apache-2.0.txt)). swift-nio and swift-log ship NOTICE files, reproduced in [Distribution/Licenses/swift-nio-NOTICE.txt](Distribution/Licenses/swift-nio-NOTICE.txt) and [Distribution/Licenses/swift-log-NOTICE.txt](Distribution/Licenses/swift-log-NOTICE.txt). Sparkle ships as a prebuilt framework inside the app; its licence, with the licences of the bsdiff, sais-lite, Ed25519 and signature-verification code it includes, is reproduced in [Distribution/Licenses/Sparkle.txt](Distribution/Licenses/Sparkle.txt). The MCP Swift SDK is moving from MIT to Apache-2.0: contributions relicensed so far are under Apache-2.0, the rest stay under the MIT License with the copyright line shown, and both apply to the pinned version.

| Package | Version | Licence | Copyright |
| -- | -- | -- | -- |
| [cocoa-aliases](https://github.com/capturecontext/cocoa-aliases) | fork | MIT | 2026 CaptureContext |
| [combine-schedulers](https://github.com/pointfreeco/combine-schedulers) | 1.2.2 | MIT | 2020 Point-Free, Inc. |
| [composable-architecture-extensions](https://github.com/capturecontext/composable-architecture-extensions) | fork | MIT | 2026 CaptureContext |
| [eventsource](https://github.com/mattt/eventsource) | 1.6.0 | MIT | 2025 Mattt (https://mat.tt) |
| [grdb.swift](https://github.com/groue/GRDB.swift) | 7.12.0 | MIT | 2015-2025 Gwendal Roué |
| [package-resources-cli](https://github.com/capturecontext/package-resources-cli) | fork | MIT | 2026 CaptureContext |
| [promptberry](https://github.com/onmyway133/promptberry) | 1.0.0 | MIT | 2026 Khoa Pham |
| [sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.1 | MIT, with BSD, zlib and MIT parts | 2006-2013 Andy Matuschak and the Sparkle authors |
| [sqlite-data](https://github.com/pointfreeco/sqlite-data) | 1.12.1 | MIT | 2025 Point-Free, Inc. |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | Apple Inc. and the Swift project authors |
| [swift-associated-objects](https://github.com/capturecontext/swift-associated-objects) | 0.3.0 | MIT | 2026 CaptureContext |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache-2.0 | Apple Inc. and the Swift project authors |
| [swift-capture](https://github.com/capturecontext/swift-capture) | 4.1.1 | MIT | 2026 CaptureContext |
| [swift-case-paths](https://github.com/pointfreeco/swift-case-paths) | 1.10.0 | MIT | 2020 Point-Free, Inc. |
| [swift-casification](https://github.com/capturecontext/swift-casification) | 0.7.0 | MIT | 2025 CaptureContext |
| [swift-clocks](https://github.com/pointfreeco/swift-clocks) | 1.1.1 | MIT | 2022 Point-Free |
| [swift-cocoa-extensions](https://github.com/capturecontext/swift-cocoa-extensions) | fork | MIT | 2026 CaptureContext |
| [swift-collections](https://github.com/apple/swift-collections) | 1.7.5 | Apache-2.0 | Apple Inc. and the Swift project authors |
| [swift-composable-architecture](https://github.com/maximkrouk/swift-composable-architecture) | fork | MIT | 2020 Point-Free, Inc. |
| [swift-concurrency-extras](https://github.com/pointfreeco/swift-concurrency-extras) | 1.4.3 | MIT | 2023 Point-Free |
| [swift-custom-dump](https://github.com/pointfreeco/swift-custom-dump) | 1.7.3 | MIT | 2021 Point-Free, Inc. |
| [swift-declarative-configuration](https://github.com/capturecontext/swift-declarative-configuration) | 0.7.1 | MIT | 2026 CaptureContext |
| [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) | 1.17.1 | MIT | 2022 Point-Free, Inc. |
| [swift-equated](https://github.com/capturecontext/swift-equated) | 0.0.6 | MIT | 2026 CaptureContext |
| [swift-foundation-extensions](https://github.com/capturecontext/swift-foundation-extensions) | 0.10.1 | MIT | 2026 CaptureContext |
| [swift-function-composition](https://github.com/capturecontext/swift-function-composition) | 0.0.3 | MIT | 2026 CaptureContext |
| [swift-identified-collections](https://github.com/pointfreeco/swift-identified-collections) | 1.1.1 | MIT | 2021 Point-Free, Inc. |
| [swift-issue-reporting](https://github.com/pointfreeco/swift-issue-reporting) | 2.1.2 | MIT | 2021 Point-Free, Inc. |
| [swift-keypath-mapping](https://github.com/capturecontext/swift-keypath-mapping) | 0.0.3 | MIT | 2026 CaptureContext |
| [swift-keypaths-extensions](https://github.com/capturecontext/swift-keypaths-extensions) | 0.2.2 | MIT | 2026 CaptureContext |
| [swift-log](https://github.com/apple/swift-log) | 1.17.0 | Apache-2.0 | Apple Inc. and the Swift Logging API project authors |
| [swift-macro-toolkit](https://github.com/maximkrouk/swift-macro-toolkit) | fork | Apache-2.0 | The swift-macro-toolkit authors |
| [swift-marker-protocols](https://github.com/capturecontext/swift-marker-protocols) | 1.5.3 | MIT | 2026 CaptureContext |
| [swift-navigation](https://github.com/maximkrouk/swift-navigation) | fork | MIT | 2021 Point-Free, Inc. |
| [swift-nio](https://github.com/apple/swift-nio) | 2.105.0 | Apache-2.0 | Apple Inc. and the SwiftNIO project authors |
| [swift-package-resources](https://github.com/capturecontext/swift-package-resources) | 5.0.1 | MIT | 2026 CaptureContext |
| [swift-parsing](https://github.com/pointfreeco/swift-parsing) | 0.15.2 | MIT | 2020 Point-Free, Inc. |
| [swift-perception](https://github.com/pointfreeco/swift-perception) | 2.0.12 | MIT | 2023 Point-Free |
| [swift-resettable](https://github.com/capturecontext/swift-resettable) | 0.3.3 | MIT | 2026 CaptureContext |
| [swift-result-builders](https://github.com/capturecontext/swift-result-builders) | 0.0.3 | MIT | 2026 CaptureContext |
| [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 | MIT and Apache-2.0 | 2024-2025 Model Context Protocol a Series of LF Projects, LLC |
| [swift-sharing](https://github.com/pointfreeco/swift-sharing) | 2.10.1 | MIT | 2024 Point-Free, Inc. |
| [swift-sharing-extensions](https://github.com/capturecontext/swift-sharing-extensions) | 0.2.0 | MIT | 2025 CaptureContext |
| [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) | 1.19.7 | MIT | 2019 Point-Free, Inc. |
| [swift-snippets](https://github.com/capturecontext/swift-snippets) | 0.1.1 | MIT | 2026 CaptureContext |
| [swift-structured-queries](https://github.com/pointfreeco/swift-structured-queries) | 0.39.2 | MIT | 2025 Point-Free, Inc. |
| [swift-subprocess](https://github.com/swiftlang/swift-subprocess) | 1.0.2 | Apache-2.0 | Apple Inc. and the Swift project authors |
| [swift-syntax](https://github.com/swiftlang/swift-syntax) | fork | Apache-2.0 | Apple Inc. and the Swift project authors |
| [swift-system](https://github.com/apple/swift-system) | 1.8.1 | Apache-2.0 | Apple Inc. and the Swift System project authors |
| [swift-tagged](https://github.com/pointfreeco/swift-tagged) | 0.10.0 | MIT | 2019 Point-Free, Inc. |
| [swift-url-routing](https://github.com/pointfreeco/swift-url-routing) | 0.7.0 | MIT | 2022 Point-Free |
| [swift-xcstrings-catalog](https://github.com/capturecontext/swift-xcstrings-catalog) | 1.0.2 | MIT | 2026 Liam Nichols, CaptureContext |
| [swiftlang-keywords](https://github.com/capturecontext/swiftlang-keywords) | 0.0.4 | MIT | 2026 CaptureContext |
| [swiftlang-snippets](https://github.com/capturecontext/swiftlang-snippets) | 0.1.1 | MIT | 2026 CaptureContext |
| [yams](https://github.com/jpsim/yams) | 6.2.2 | MIT | 2016 JP Simard |

## Helium's !bang list

`Packages/core/Sources/BrowserCore/Resources/Bangs.tsv` is generated by `make bangs` from Helium's bang list, <https://services.helium.imput.net/bangs.json>. The list combines [Kagi Search's bangs](https://github.com/kagisearch/bangs) with imput's additions. The generated file repeats this licence in its header and ships inside the BrowserCore resource bundle.

```text
MIT License

Copyright (c) 2024 Kagi Search, 2026 imput

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
```

## Mozilla Readability

Reading mode reads a page's article with Mozilla Readability 0.6.0 (<https://github.com/mozilla/readability>), Copyright (c) 2010 Arc90 Inc, under the Apache License, Version 2.0 ([Distribution/Licenses/Apache-2.0.txt](Distribution/Licenses/Apache-2.0.txt)). Its `Readability.js` and `Readability-readerable.js` are in `Packages/services/Sources/PageReaderClient/Resources/` with their comments and indentation taken out (`Scripts/strip_js.py`), beside the package's licence notice, `Readability-LICENSE.md`.

## Arx Wordmark font

`Packages/design-system/Sources/AppUI/Resources/Fonts/ArxWordmark-Regular.ttf` is a modified version of Comfortaa, renamed "Arx Wordmark", with its weight axis extended to 1000. Copyright 2011 The Comfortaa Project Authors (<https://github.com/alexeiva/comfortaa>), with Reserved Font Name "Comfortaa". It is licensed under the SIL Open Font License 1.1. The full licence ships beside the font as `ArxWordmark-OFL.txt` and is available at <https://openfontlicense.org>.
