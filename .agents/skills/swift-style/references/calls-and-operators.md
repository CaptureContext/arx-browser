# Calls and Operators

- [Function calls](#function-calls)
- [Operators](#operators)

## Function calls

Keep one-argument calls and short calls on one line when they remain easy to scan. Inline multiple arguments when the statement is compact, especially when the first argument is unlabeled.

```swift
print(sum(2, 2)) // 4

let _sum = curry(sum)
let addOneTo = _sum(1)
print(addOneTo(2)) // 3

super.viewDidAppear(animated: animated)
```

Use separate lines when labels, argument expressions, or the surrounding statement carry enough visual weight to benefit from stronger separation.

```swift
let cardView: CardView = .init(
	model: cardModel,
	style: cardStyle
)
```

When the type is explicit on the left, omit it on the right.

```swift
let value: Value = .custom(0)
let view: SomeView = .init()
let manager: SomeManager = .init(
	param1: 0,
	param2: "test"
)
```

With `swift-declarative-configuration`, shape trailing closures as follows.

```swift
// Type is explicit on the right side
// instead of the left side
let redRoundedView = CocoaView() { $0
	.backgroundColor(.red)
	.layer.scope { $0
		.cornerCurve(.continuous)
		.cornerRadius(12)
	}
}
```

> [!Important]
>
> Never use Objective-C-style call alignment in Swift.
>
> ```swift
> // WRONG ❌
> someFunction(arg1: 0
> 						arg2: 1)
>
> // CORRECT ✅
> someFunction(
> 	arg1: 0,
> 	arg2: 1
> )
> ```
>
> This matters because:
>
> - indentation declares visual context, and Objective-C-style alignment weakens it
>
>   ```
>   // bad visual separation of contexts
>   <identifier>(<first-arg-line>
>                <next-arg-lines>)
>   ```
>
>   vs
>
>   ```
>   // good visual separation of contexts
>   <identifier>(
>   	<arg-lines>
>   )
>   ```
>
>   - Objective-C-style alignment does not work well with tab indentation

## Operators

Align multiline ternaries with the expression instead of Xcode's continuation indentation.

```swift
// WRONG: Fights Xcode indentation
let value = condition
	? true
	: false

// CORRECT: Matches Xcode indentation
let value = condition
? true
: false

// CORRECT: It's ok to keep ternary as one-liner for simple expressions
let value = condition ? true : false
```

Lead continuation lines with their operators.

```swift
// WRONG: Trailing operators chaining
let value = condition1 && (
	condition2 ||
	condition3 ||
	condition4
) && condition5

let f = f3 <<<
f2 <<<
f1 <<<
f0

// CORRECT: Leading operators chaining
let value = condition1
&& (
	condition2
	|| condition3
	|| condition4
)
&& !condition5

let f = f3
<<< f2
<<< f1
<<< f0

// CORRECT: Often times leading chaining can be restructured a bit
// Note - restructure only if it doesn't affect performace
let value = condition1
&& !condition5
&& (
	condition2
	|| condition3
	|| condition4
)

// CORRECT: Simple expressions can be one-liners
let value = condition1 && (condition2 || condition3)
let f = f3 <<< f2 <<< f1 <<< f0
```
