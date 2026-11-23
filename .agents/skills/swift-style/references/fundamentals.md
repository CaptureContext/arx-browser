# Fundamentals

## Core principles

**Clarity > Brevity > Consistency**

Keep code free of compiler warnings.

## Indentation

- Follow the nearest `.editorconfig`.
- If `.editorconfig` is missing in an existing project, infer the project's indentation and create one.
- For new projects, copy [`assets/.editorconfig`](../assets/.editorconfig) from this skill. It contains:

  ```ini
  root = true

  [*]
  indent_style = tab
  tab_width = 2
  trim_trailing_whitespace = true
  insert_final_newline = true

  [*.yml]
  indent_style = space
  indent_size = 2
  ```

  > [!Important]
  >
  > `yaml` files should always be indented with spaces, `Makefile`s should also be indented with tabs

- For forks or subprojects, prefer their local `.editorconfig` over the root configuration.
- Use tabs in every Swift example authored for CaptureContext and Point-Free skills. Preserve Markdown nesting prefixes around fenced examples, but indent the Swift inside the fence with tabs.

## Naming

- Use `PascalCase` for types and protocols.
- Use `camelCase` for everything else.
- Prefix private or internal APIs with `_` or `__` when they mirror a less restrictive API or are exposed through `@_spi`.
- Optimize names for clarity at the call site.
- Avoid abbreviations except universal ones such as URL, ID, idx, and ios.
	- Keep every letter of an acronym in the same case (`url`/`URL`, `id`/`ID`).
	- Allow non-acronym abbreviations such as idx/Idx and branded names. When a brand always starts lowercase and is not the first identifier token, prefix it with an underscore (`ios`/`_iOS`).
	- Allow simple argument names in very small or generic functions.

	  ```swift
	  func sum(_ a: Int, _ b: Int) -> Int { a + b }
	  ```

	  ```swift
	  func pipe<A, B, C>(
	  	_ f0: @escaping (A) -> B,
	  	_ f1: @escaping (B) -> C
	  ) -> (A) -> C {
	  	return { a in f1(f0(a)) }
	  }
	  ```

- Use `Internals` as the default SPI name: `@_spi(Internals)`.

```swift
let maximumWidgetCount = 100
func fetchUser(byID id: String) -> User
```
