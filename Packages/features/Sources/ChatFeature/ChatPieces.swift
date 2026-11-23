import AgentClient
import SwiftUI

/// The provider's mark: ✳︎ for Claude, a symbol for the others.
internal struct ChatProviderMark: View {
	internal let provider: AgentProvider

	internal init(_ provider: AgentProvider) {
		self.provider = provider
	}

	internal var body: some View {
		Group {
			if provider == .claude {
				Text(verbatim: "✳︎").font(.system(size: 11, weight: .semibold))
			} else {
				Image(systemName: provider.symbol).font(.system(size: 9, weight: .bold))
			}
		}
		.accessibilityHidden(true)
	}
}
