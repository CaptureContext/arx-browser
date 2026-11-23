# Runtime and Documentation Practices

- [Memory management](#memory-management)
- [Comments](#comments)
- [Omitting errors](#omitting-errors)
- [Common mistakes](#common-mistakes)

## Memory management

Capture `self` weakly when an escaping closure should not retain its owner.

```swift
resource.request().onComplete { [weak self] response in
	guard let self else { return }
	self.updateModel(response)
}
```

If `swift-capture` is available:

```swift
resource.request().onComplete(perform: capture { _self, response in
	_self.updateModel(response)
})
```

## Comments

- Explain **why**, not what.
- Use `//` or `///`; avoid `/* */`.
- In documentation comments, always prefer a `- Parameters` list to individual `- Parameter` entries, even for one parameter.
- Keep comments current or delete them.
- Leave a blank line before a comment, documentation comments included, when it follows code in the same scope. Do not add one when the comment is the first line of its scope, continues an expression (inside an argument or element list), or follows an attribute or compiler directive.

  ```swift
  // WRONG ❌
  public var id: UUID
  /// The app's name as the prompt shows it.
  public var name: String

  // CORRECT ✅
  public var id: UUID

  /// The app's name as the prompt shows it.
  public var name: String
  ```
- Use `// MARK:` comments in complex files.
  - Highlight semantic sections with `// MARK: -`.
  - Mark subsections with `// MARK:`.

## Omitting errors

When an error intentionally does not receive full handling—for example during an initial implementation or observation—prefer Point-Free's `IssueReporting` to `try?` or printing in `catch`.

```swift
// WRONG ❌: Error is completely ignored
try? produceError()

// WRONG ❌: API is not very ergonomic
// and `print` is not the best logging strategy
do {
	try produceError()
} {
	print(error)
}

// CORRECT ✅: Delegates handling to reporters API
// depending on context reporters can use osLog or raise
// a runtime warning underthehood
withErrorReporting {
	try produceError()
}
```

## Common mistakes

1. **Abbreviations beyond URL, ID, UUID** — Spell out abbreviations such as `cfg` and `mgr` as `configuration` and `manager`.
   - Allow `ctx` for context, though discourage it.
   - Allow `idx` for index, though discourage it.
   - Prefer well-known acronyms such as `ID`, `UUID`, `URL`, and `URI`.
2. **Nested guard/if statements** — Prefer early returns and guards so the happy path stays left-aligned. Allow nesting only when it improves readability.
3. **Inconsistent `self` usage** — Follow the surrounding project's more frequent convention. Require explicit `self` for stored-property assignments in initializers and for other instance-member accesses in methods that call `super`. Prefer omitting unnecessary `self` in structs outside initializers.
4. **Overly generic type names** — Avoid vague names such as `Manager`, `Handler`, `Helper`, and `Coordinator`. Name the responsibility: `PaymentProcessor`, `EventDispatcher`, `ImageCache`, or `MainCoordinator`.
   - Allow them for rare generic components such as `Handler<each T>`.
   - Allow them for nested types when the namespace already supplies the domain.
5. **Implied access control in production code** — Specify `private`, `internal`, `package`, or `public` so module boundaries remain clear. Focused examples in other skills may omit access control to showcase an unrelated API; treat it as elided, never as production guidance.
6. **Attributes on the declaration line** — Put every attribute on its own line.
