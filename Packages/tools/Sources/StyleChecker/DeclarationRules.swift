import SwiftSyntax

// Rules from the guide's declarations reference.

extension StyleVisitor {
	// MARK: - Attributes

	// ❌ @objc internal let name: String
	internal func checkAttributePlacement(_ node: AttributeListSyntax) {
		// Declaration attributes only: parameter, type and closure attributes such as `@escaping`
		// and `@MainActor in` sit inline. Imports keep `@testable` and `@_exported` on their line.
		guard
			let declaration = node.parent?.as(DeclSyntax.self),
			!declaration.is(ImportDeclSyntax.self)
		else { return }

		for attribute in node {
			guard
				let lastToken = attribute.lastToken(viewMode: .sourceAccurate),
				let nextToken = lastToken.nextToken(viewMode: .sourceAccurate),
				file.startLine(of: nextToken) == file.endLine(of: lastToken)
			else { continue }

			file.report(.attributeOwnLine, at: attribute.positionAfterSkippingLeadingTrivia)
		}
	}

	// ❌ @State
	internal func checkStateAttribute(_ node: AttributeSyntax) {
		guard node.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "State"
		else { return }

		file.report(.swiftUIStateQualified, at: node.positionAfterSkippingLeadingTrivia)
	}

	// ❌ @Dependency(\.someDependency1)
	// var someDependency1
	// @Dependency(\.someDependency2)
	// var someDependency2
	internal func checkAttributedSpacing(_ items: [Syntax]) {
		for (index, item) in items.enumerated() where Self.hasAttributes(item) {
			let firstLine: Int = file.firstLineIncludingComments(of: item)

			if index > 0, !file.isBlank(line: firstLine - 1) {
				file.report(
					.attributedDeclarationSpacing,
					at: item.positionAfterSkippingLeadingTrivia,
					message: "An attributed declaration needs a blank line before it."
				)
			}

			// A following attributed declaration reports its own missing line.
			let next: Syntax? = items.indices.contains(index + 1) ? items[index + 1] : nil
			guard let next, !Self.hasAttributes(next) else { continue }

			if !file.isBlank(line: file.firstLineIncludingComments(of: next) - 1) {
				file.report(
					.attributedDeclarationSpacing,
					at: next.positionAfterSkippingLeadingTrivia,
					message: "A declaration after an attributed one needs a blank line before it."
				)
			}
		}
	}

	// `@testable import` is an import, grouped with the others, not an attributed declaration.
	private static func hasAttributes(_ node: Syntax) -> Bool {
		guard
			!node.is(ImportDeclSyntax.self),
			let declaration = node.asProtocol(WithAttributesSyntax.self)
		else { return false }

		return !declaration.attributes.isEmpty
	}

	// MARK: - Property types

	// ❌ private var canGoForward = false
	internal func checkPropertyType(_ node: VariableDeclSyntax) {
		// Properties only: the guide lets local variables infer their type.
		guard node.parent?.is(MemberBlockItemSyntax.self) == true else { return }

		for binding in node.bindings {
			guard
				binding.typeAnnotation == nil,
				binding.pattern.is(IdentifierPatternSyntax.self),
				let value = binding.initializer?.value
			else { continue }

			// let someView = SomeView() { $0
			// 	.backgroundColor(.red)
			// }
			// Declarative configuration names the type on the right side, as the guide's note asks.
			if value.as(FunctionCallExprSyntax.self)?.trailingClosure != nil { continue }

			file.report(.explicitPropertyType, at: binding.pattern.positionAfterSkippingLeadingTrivia)
		}
	}
}
