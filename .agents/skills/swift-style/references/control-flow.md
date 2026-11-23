# Control Flow

- [Conditional statements](#conditional-statements)
- [Vertical whitespace](#vertical-whitespace)
- [Guard](#guard)
- [If](#if)
- [Switch](#switch)
- [Ternary operators](#ternary-operators)
- [Golden path](#golden-path)
- [Self](#self)

## Conditional statements

Choose expression shapes for ergonomics and clear visual separation between domains:

> ```swift
> // MARK: CORRENT ✅ no separation, but the expression is
> // super simple and doesn't need it
> guard let self else { return }
>
> // MARK: CORRENT ✅ soft [condition vs else] separation,
> // this might be a bit redundant, but still reads well
> guard let self
> else { return }
>
> // MARK: CORRENT ✅ soft [condition vs else] separation
> // for simple conditions and else branches, or when both
> // branches have approximately equal lengths
> guard let first = candidates.first(where: condition)
> else { throw LocalError.noMatchingCandidatesFound }
>
> // MARK: CORRENT ✅ else block separation with indentation
> // when else branch is complex/multiline
> guard let self else {
> 	logger.logError("self is missing")
> 	service.cleanup()
> 	return
> }
>
> // MARK: CORRENT ✅ else block separation with indentation
> // when else branch is much longer than the condition,
> // this balances out the weight of the expression
> guard let self else {
> 	throw LocalError.somthingUnexpectedHappened
> }
>
> // MARK: CORRENT ✅ complex conditions are visually separated with indentation,
> // simple else block is on a separate line
>
> // extracted complex expression out of the guard statment
> // to simplify it
> var firstInt: Int? { strings.first { Int($0) }.flatMap { Int($0) } }
> guard
> 	let self,
> 	let firstInt,
> 	firstInt.isMultiple(of: 2)
> else { return nil }
>
> // MARK: CORRENT ✅ conditions and else branch both
> // are strongly visually separated with indentation
> guard
> 	let self,
> 	let firstInt,
> 	firstInt.isMultiple(of: 2)
> else {
> 	logger.logError("something went wrong")
> 	service.cleanup()
> 	throw LocalError.unexpectedFailure
> }
>
> // MARK: WRONG ❌ Expression is too long to be defined
> // as a one-liner, `else { return }` must be placed on a new line
> guard let pattern = loadAHAPPattern(named: "ShieldTransient") else { return }
>
> // MARK: WRONG ❌ `else` branch is approximately the same length
> // as the condition, expression would be more balanced as a two-liner
> // `throw` should be placed on the same line as `else {` as well as `}`
> guard let pattern = loadAHAPPattern(named: "ShieldTransient")
> else {
> 	throw Failure.couldNotLoadAHAPPPattern
> }
>
> // MARK: WRONG ❌ not enough visual separation, conditions are complex enough,
> // but the first one competes with `guard` keyword for reader's attention.
> // Also such separation doesn't work well with tabs indentation.
> // `let self` must be placed on a new line, other conditions indentations
> // should be adjusted
> guard let self,
> 	let firstInt,
> 	firstInt.isMultiple(of: 2)
> else { return nil }
>
> // MARK: WRONG ❌ both condition and else branch
> // are equally super simple, but else branch separation
> // is too strong
> guard let self else {
> 	return nil
> }
>
> // MARK: WRONG ❌ both condition and else branch
> // are equally super simple, but else branch is much
> // longer than the condition and this could be more balanced
> guard let self
> else { throw LocalError.somthingUnexpectedHappened }
> ```

Apply the same visual-separation approach to other conditional statements, function declarations and calls, and generic constraints:

> ```swift
> // WRONG ❌ Expression takes too much space and could be optimized
> class MyComplexCustomView<CompexCustomDelegate, ComplexCustomDataSource, Content> { ... }
>
> // CORRECT: ✅ Clear visual separation of type identifier and generic constraints
> class MyComplexCustomView<
> 	CompexCustomDelegate,
> 	ComplexCustomDataSource,
> 	Content
> > { ... }
> ```

## Vertical whitespace

Use blank lines to reveal semantic structure, not mechanically after a particular kind or number of statements.

For sequential code, arrange statements into logical paragraphs:

- Keep statements together when they read as one continuous step.
- Allow a sequence of simple `guard` statements to remain uninterrupted regardless of its length.
- When guards or other statements form meaningful subgroups, keep each subgroup together and separate the groups with blank lines.
- Give a complex statement its own paragraph when doing so improves the surrounding flow.
- Do not add blank lines when they fail to communicate a useful grouping.

For alternative control flow, keep sibling formatting consistent:

- Keep an entire `if` chain or `switch` compact when every handler is compact.
- If any branch or case is sufficiently complex to benefit from separation, promote the whole construct to expanded layout.
- In an expanded `if` chain, add a blank line before every subsequent `} else`.
- In an expanded `switch`, add a blank line before every case except the first.
- Apply this separation to simple sibling handlers too, so the construct has one consistent rhythm.

## Guard

Keep a short `guard` on one line when its `else` block is simple. Use a multiline block for custom logic or multiple calls.

```swift
guard let self else { return }

guard let self else { return fallback() }

guard let self else {
	// custom logic or multiple external calls
	return nil
}
```

Use two lines for a medium `guard`, especially when `else` contains one function call, return, or throw:

```swift
guard input.someConditionThatMustBeSatisfied()
else { return cleanup() }
```

```swift
guard input.someConditionThatMustBeSatisfied()
else { throw LocalError.inputCorrupted }
```

```swift
guard input.someConditionThatMustBeSatisfied() else {
	// custom logic or multiple external calls
	return
}
```

Put every non-trivial multiline condition on its own line. Keep simple returns with `else`; expand complex branches.

```swift
guard isNumber, isFinite
else { return nil }
```

```swift
guard
	input.firstCondition,
	input.secondCondition
else { return }
```

```swift
guard
	input.firstCondition,
	input.secondCondition
else {
	// some more work
	return
}
```

Group adjacent guards by meaning. A flat sequence needs no blank lines when separating it would not improve the flow:

```swift
guard let input else { return nil }
guard input.isValid else { return nil }
guard cache[input.id] == nil else { return nil }
```

Use blank lines when they reveal distinct stages or meaningful subgroups:

```swift
guard let input else { return nil }

guard input.isValid else { return nil }
guard input.isSupported else { return nil }

guard cache[input.id] == nil else { return nil }
guard permissions.canStore(input) else { return nil }
```

Never use these shapes:

```swift
// ❌
// first condition on the `guard` line
// second condition on a new line, aligned with condition1 with spaces
//
// Could be fixed by moving the first condition to a new line
guard condition1
			conditionN
else ...

// ❌
// first condition on the `guard` line
// else is on a new line and is multiline
//
// could be fixed by placing `else {` on the same line
// as `guard condition` like `guard condition else {`
// or moving a condition to a new line
guard condition
else {
	// ...
}
```

## If

Keep a simple `if` on one line.

```swift
if exitEarly { return }
```

Avoid multiline condition lists. Keep short conditions together; otherwise extract a named local value.

```swift
if isNumber, isFinite {
	// work
} else {
	// other work
}
```

```swift
let isOddNumberValidAndCached = cache.contains(number)
&& validate(number)
&& !number.isMultiple(of: 2)

if isOddNumberValidAndCached {
	// work
}
```

## Switch

Use `case let ._(value)` instead of `case ._(let value)`. Depart from this form only when required by the compiler.

Handle simple cases on one line.

```swift
switch self {
case .normal: .normal
case .custom: .custom
}
```

Put medium case bodies on a new line.

```swift
switch action {
case .someWork:
	// perform some work
case .someOtherWork:
	// perform some other work
}
```

When any case is complex enough to benefit from separation, separate every case in the switch for consistency, including otherwise simple sibling cases.

```swift
switch action {
case .someWork1:
	// perform some work1

case .someWork2:
	// perform some work2

case .someWork3:
	// perform some work3
}
```

Apply the same consistent separation to every branch in an `if` chain when any branch is complex.

```swift
if condition {
	// complex logic

} else if otherCondition {
	// even a simple sibling receives the same separation

} else {
	// else block is prefixed with
	// a trailing newline in `if` block
}
```

## Ternary operators

Allow nested ternaries only for very simple mappings; generally avoid nesting them.

```swift
return isPrimeRequred
? (isRandom ? primeCandidates.random() : primeCandidates.first)
: (isRandom ? allCandidates.random() : allCandidates.first)
```

Prefer a ternary over an `if` expression for simple assignments.

```swift
let output: String = if forceUppercase { string.uppercased() } else { string } // ❌
let output = forceUppercase ? string.uppercased() : string // ✅
```

Prefer `switch` over ternaries for complex assignments.

```swift
// ❌
let value = input == .zero
? 0 : input == .one
? 1 : .max

// ✅
let value: Int = switch input {
case .zero: 0
case .one: 1
case .max: .max
}
```

## Golden path

Keep the happy path on the left margin. Avoid redundant `if` nesting.

```swift
func process(value: Int?) throws -> Result {
	guard let value else { throw ProcessError.nilValue }
	guard value > 0 else { throw ProcessError.negativeValue }
	return compute(value)
}
```

## Self

Follow the more frequent `self` convention in the surrounding project. When a method contains a `super` call, explicitly qualify its other instance-member accesses with `self`. In structs, omit `self` when it is unnecessary except in initializers, where stored-property assignments must use `self`.

```swift
// Without swift-declarative-configuration
override func _init() {
	super._init()
	self.backgroundColor = .systemBackground
}
```

```swift
// With swift-declarative-configuration
override func _init() {
	super._init()
	self.configure { $0
		.backgroundColor(.systemBackground)
	}
}
```
