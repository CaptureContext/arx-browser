import StyleChecker
import Testing

/// The declarations reference's examples.
internal struct DeclarationRuleTests {
	@Test
	internal func guideCorrectDeclarationsPass() {
		let source: String = """
			@Reducer
			struct CustomFeature {
				@SwiftUI.State
				private var value: Int = 0

				@Dependency(\\.someDependency)
				private var someDependency

				@Dependency(\\.someDependency1)
				var someDependency1

				@Dependency(\\.someDependency2)
				var someDependency2

				let value: Int = 0
				var object: AnyObject?

				let someView = SomeView() { $0
					.backgroundColor(.red)
					.alpha(0.8)
				}

				@inlinable
				func test() {}

				@available(
					*, deprecated,
					message: \"""
					Don't use this method,
					it's deprecated
					\"""
				)
				@objc
				func test() {}

				func run(_ operation: @escaping @MainActor () -> Void) {
					let statuses = try await Product.SubscriptionInfo.status(for: groupID)
				}
			}
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}

	@Test
	internal func attributeOnTheDeclarationLine() {
		let source: String = """
			struct Wrong {
				@objc internal let name: String

				@Dependency(\\.uuid) private var uuid
			}
			"""

		#expect(lines(.attributeOwnLine, in: source) == [2, 4])
	}

	@Test
	internal func attributedDeclarationsNeedBlankLines() {
		let source: String = """
			struct Wrong {
				@Dependency(\\.someDependency1)
				var someDependency1
				@Dependency(\\.someDependency2)
				var someDependency2
				let value: Int = 0
			}
			"""

		#expect(lines(.attributedDeclarationSpacing, in: source) == [4, 6])
	}

	@Test
	internal func importsKeepTestableInTheirGroup() {
		let source: String = """
			import Foundation
			@testable import StyleChecker
			import Testing
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}

	@Test
	internal func unqualifiedSwiftUIState() {
		let source: String = """
			struct Wrong: View {
				@State
				private var value: Int = 0
			}
			"""

		#expect(lines(.swiftUIStateQualified, in: source) == [2])
	}

	@Test
	internal func propertyTypeInferredFromItsValue() {
		let source: String = """
			struct Wrong {
				private var canGoForward = false
				private static let page = URL(string: "https://example.com")!

				@SwiftUI.State
				private var value = 0

				func work() {
					let local = 0
				}
			}
			"""

		#expect(lines(.explicitPropertyType, in: source) == [2, 3, 6])
	}
}
