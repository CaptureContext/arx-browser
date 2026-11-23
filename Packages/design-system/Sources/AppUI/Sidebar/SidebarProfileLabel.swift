import SwiftUI

/// Which profile a space belongs to.
public struct SidebarProfileLabel: View {
	private let name: String

	public init(name: String) {
		self.name = name
	}

	public var body: some View {
		HStack(spacing: 4) {
			Image(systemName: "face.smiling")
				.font(.system(size: 12, weight: .medium))
			Text(name)
				.font(.system(size: 12, weight: .medium))
				.lineLimit(1)
		}
		.foregroundStyle(BrowserTheme.secondary)
		.accessibilityElement(children: .combine)
	}
}
