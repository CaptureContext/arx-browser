# Declarations

- [General rules](#general-rules)
- [Declaration structure](#declaration-structure)
- [Functions](#functions)
- [Type declarations](#type-declarations)

## General rules

- Specify access control in production code so module boundaries remain clear.

  Focused examples in other skills may omit access control when it is unrelated to the API being demonstrated. The omission is illustrative only: never infer that production code should use implied access control.

- Specify property types explicitly unless an attached macro or property wrapper determines the type as part of its own contract.

  ```swift
  let value: Int = 0
  var object: AnyObject?
  ```

  > [!Note]
  >
  > Specifically when using `swift-declarative-configuration` use the following pattern to avoid hitting a runtime swift bug with `callAsFunction` calls:
  >
  > ```swift
  > // Type is implicit on the left side
  > // Type is explicit on the right side
  > let someView = SomeView() { $0
  > 	.backgroundColor(.red)
  > 	.alpha(0.8)
  > }
  > ```

  Allow these exceptions:

  - Macros and property wrappers that determine their type from a key path or fixed wrapped-value contract, such as `@Environment` and `@Dependency`.

  - Do not normally infer a property type merely from its default value. Prefer an explicit type even when the initializer makes it obvious.

  - Local variables with long but simple initialization code:

    ```swift
    // WRONG ❌: Expression is too long
    let statuses: [Product.SubscriptionInfo.Status] = try await Product.SubscriptionInfo.status(for: groupID)

    // CORRECT ✅: This code is easier to read and type
    // is not as important for local variables as for properties
    let statuses = try await Product.SubscriptionInfo.status(for: groupID)

    // CORRECT ✅: Type can be kept if we move initialization code to the next line
    let statuses: [Product.SubscriptionInfo.Status] =
	try await Product.SubscriptionInfo.status(for: groupID)
    ```

- Use syntactic sugar for first-class Swift types.

  - Prefer `Value?` to `Optional<Value>`.

    ```swift
    let value: Int? = nil
    ```

  - Prefer `[Value]` to `Array<Value>`.

    ```swift
    let array: [Int] = []
    ```

  - Prefer `[Key: Value]` to `Dictionary<Key, Value>`.

    ```swift
    let dict: [String: Int] = [:]
    ```

  - Keep explicit types for custom collections such as `IdentifiedArray` and `OrderedSet`.

  - Prefer an explicit type plus a `where` clause in extensions.

      ```swift
      extension Array where Element: StringProtocol { ... }
      ```

- Put every attribute on its own line.

  ```swift
  @Reducer
  struct CustomFeature { ... }

  @SwiftUI.State
  private var value: Int = 0

  // If type is inferred from the propertyWrapper
  // initializer, it should be omitted from the variable
  // Usually only applicable to @Environment and @Dependency
  @Dependency(\.someDependency)
  private var someDependency

  @inlinable
  func test() {}

  @objc
  func test() {}

  @available(
  	*, deprecated,
  	message: """
  	Don't use this method,
  	it's deprecated
  	"""
  )
  @objc
  func test() {}
  ```

  - In general-purpose packages, mark public functions `@inlinable` and internal properties or functions `@usableFromInline`.

  - Always qualify SwiftUI state as `@SwiftUI.State`, not `@State`.

  - Treat an attribute stack and its declaration as one unit. Separate every attributed declaration from adjacent declarations with a blank line. Keep multiple attributes belonging to the same declaration together.

    ```swift
    // WRONG ❌
    @Dependency(\.someDependency1)
    var someDependency1
    @Dependency(\.someDependency2)
    var someDependency2

    // Correct ✅
    @Dependency(\.someDependency1)
    var someDependency1

    @Dependency(\.someDependency2)
    var someDependency2

    let value: Int = 0
    ```

- Omit `get` from read-only computed properties.

  - Prefer one line for a simple read-only computed property when it remains easy to scan. Expand it when the declaration is already long, the expression carries visual weight, or multiline formatting is more consistent with neighboring declarations.

    ```swift
    var diameter: Double { radius * 2 }
    ```

## Declaration structure

Order declaration components as:

- attributes
- access modifier
- `override`
- `static`/`final`
- identifier
- type

```swift
open override static var value: Int
```

## Functions

Keep a simple one-argument function in this shape:

```swift
func test(_ value: Int) {}
```

Put multiple arguments on separate lines except in trivial cases.

```swift
func sum(_ a: Int, _ b: Int) -> Int { a + b } // ok even as a one-liner
```

```swift
// this one must declare each arg on a new line
func sendRequest(
	_ request: URLRequest,
	using session: URLSession
) async throws -> (Data, Response) {
	// body
}
```

For a function generic over one type, put its argument on a new line unless the whole function is very simple.

```swift
func identifier<Arg>(
	_ arg: Arg
) -> Output {
	// body
}
```

Keep a simple generic constraint in the generic argument list.

```swift
func identifier<Arg: Equatable>(
	_ arg: Arg
) -> Output {
	// body
}
```

Put multiple generic arguments and function arguments on separate lines.

```swift
func identifier<
	Arg1,
	Arg2
>(
	_ arg1: Arg1,
	_ arg2: Arg2
) -> Output {
	// body
}
```

Move complex constraints to a `where` clause. When a `where` clause is required, move all constraints there and place multiple expressions on separate lines.

```swift
@inlinable
public static func someFunction<
	Arg1,
	Arg2
>(
	_ arg1: Arg1,
	_ arg2: Arg2
) async throws -> Output where
	Arg1: Equatable & Sendable,
	Arg2: Equatable & Sendable
{
	// body
}
```

## Type declarations

Order type contents as follows:

- operator overrides, such as `==` for `Equatable`
- stored properties
  - plain or `@usableFromInline`, ordered semantically or by access: `private` → `internal` → `package` → `public` → `open`
  - property-wrapped or macro-attributed, ordered the same way
- initializers
  - convenience
  - designated
  - required
  - initialization helpers such as `_init`
  - method overrides for classes
- computed properties
- methods
  - `hash(into:)` when needed
  - other methods
- extensions
  - extracted computed properties, helpers, and nested types
- local extensions of imported types

### Structs

- Do not give stored properties default values.
- Always generate an initializer; use default arguments when needed.
- Usually provide one designated initializer accepting every property. Make convenience initializers call it.
- Always assign stored properties through `self` in initializers.
- Focused skill examples may omit an initializer when initialization is unrelated to the demonstrated API. Treat the initializer as elided and add it in production code.

### Enums

- Start with enum cases.
- Allow nested types in the base enum declaration after the cases; do not require a separate extension.

### Classes

- Mark a class `final` when it is not intended for subclassing.
