---
name: swift-style
description: "Apply an opinionated Swift style focused on visual structure, explicit declarations, call-site clarity, and warning-free code. Use whenever writing, editing, reviewing, or formatting Swift code, including APIs, control flow, type declarations, calls, closures, and documentation."
---

# Swift Style

Write clear, readable Swift with deliberate visual structure.

**Clarity > Brevity > Consistency**

Keep code free of compiler warnings. Treat the guide's correct and incorrect examples as normative, including their indentation and line-break choices.

## Load the relevant rules

Read [fundamentals](references/fundamentals.md) for every Swift task. Then read every reference that touches the code being changed:

- [Control flow](references/control-flow.md) — guards, conditionals, switches, ternaries, golden-path structure, and explicit `self`.
- [Declarations](references/declarations.md) — properties, attributes, functions, generics, type layout, structs, enums, and classes.
- [Calls and operators](references/calls-and-operators.md) — argument layout, declarative configuration closures, ternaries, and operator chains.
- [Runtime and documentation practices](references/runtime-practices.md) — captures, comments, intentionally omitted errors, and recurring mistakes.

For a new file, new type, public API, or broad style review, read all references before drafting.

## Apply the style

1. Read the nearest `.editorconfig` and inspect surrounding Swift for project-local constraints. If a new project has none, copy `assets/.editorconfig` into its root.
2. Load the relevant references before editing.
3. Match the guide's semantic grouping and visual separation; do not flatten intentional layouts into formatter defaults.
4. Keep changes scoped. Do not restyle unrelated code unless the user asks for a style pass.
5. Compile or type-check when practical and remove warnings introduced by the change.

Let a more local `.editorconfig` control indentation in forks and subprojects. When existing code disagrees with this guide in a way that appears deliberate or externally constrained, preserve it and surface the conflict instead of silently rewriting it.

Focused examples in other skills may omit access modifiers, explicit initializers, or unrelated declarations to keep attention on the showcased API. Treat those omissions as elisions, not production conventions. Apply this guide fully when writing production code.
