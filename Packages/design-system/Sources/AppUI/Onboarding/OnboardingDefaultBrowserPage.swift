import BrowserCore
import SwiftUI

/// "Links from other apps": Mail and Messages beside a small Arx window, and a line
/// saying where links open now.
///
/// Make Default and Not Now are in the footer, which the onboarding window draws.
public struct OnboardingDefaultBrowserPage: View {
	/// What the line under the illustration says.
	public enum Note: Equatable, Sendable {
		/// Not checked yet, or it can't be read; the line stays empty.
		case none

		case isDefault

		/// Another app opens links, named when macOS reports it.
		case otherBrowser(String?)

		/// The person declined macOS's confirmation.
		case declined
	}

	public let note: Note
	public let hasAppeared: Bool

	/// - Parameters:
	///   - hasAppeared: Starts the illustration in its final state, for snapshots.
	public init(
		note: Note,
		hasAppeared: Bool = false
	) {
		self.note = note
		self.hasAppeared = hasAppeared
	}

	public var body: some View {
		OnboardingPageLayout(
			title: OnboardingStep.defaultBrowser.headline,
			message: OnboardingStep.defaultBrowser.message
		) {
			VStack(spacing: 16) {
				OnboardingLinksIllustration(hasAppeared: hasAppeared)
				noteLine
			}
		}
		.onChange(of: note) { _, note in
			guard note == .isDefault || note == .declined else { return }

			AccessibilityNotification.Announcement(noteText(note)).post()
		}
	}

	@ViewBuilder
	private var noteLine: some View {
		Group {
			switch note {
			case .isDefault:
				Label {
					Text(noteText(note))
				} icon: {
					Image(systemName: "checkmark.circle.fill")
						.foregroundStyle(.green)
				}

			case .none:
				// Keeps the line's height, so the page doesn't move once it's checked.
				Text(verbatim: " ")
					.accessibilityHidden(true)

			case .otherBrowser, .declined:
				Text(noteText(note))
			}
		}
		.font(.callout)
		.foregroundStyle(.secondary)
		.multilineTextAlignment(.center)
		.fixedSize(horizontal: false, vertical: true)
	}

	private func noteText(_ note: Note) -> String {
		switch note {
		case .none:
			""

		case .isDefault:
			String.localized(.appUI.onboarding.defaultBrowser.isDefault)

		case let .otherBrowser(name?):
			String.localized(.appUI.onboarding.defaultBrowser.current(name))

		case .otherBrowser(nil):
			String.localized(.appUI.onboarding.defaultBrowser.currentUnknown)

		case .declined:
			String.localized(.appUI.onboarding.defaultBrowser.declined)
		}
	}
}

/// Mail and Messages beside a small Arx window that has just opened a shared link.
///
/// The page slides into the window once when it appears; under Reduce Motion it only fades.
/// VoiceOver reads the whole illustration as one image.
public struct OnboardingLinksIllustration: View {
	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var hasAppeared: Bool

	/// - Parameters:
	///   - hasAppeared: Starts in the final state, for snapshots.
	public init(hasAppeared: Bool = false) {
		self._hasAppeared = .init(initialValue: hasAppeared)
	}

	public var body: some View {
		HStack(spacing: 44) {
			VStack(spacing: 28) {
				OnboardingAppTile(
					symbol: "envelope.fill",
					colors: [
						.init(red: 0.25, green: 0.62, blue: 1),
						.init(red: 0.06, green: 0.4, blue: 0.95),
					]
				)
				OnboardingAppTile(
					symbol: "message.fill",
					colors: [
						.init(red: 0.36, green: 0.89, blue: 0.4),
						.init(red: 0.12, green: 0.72, blue: 0.24),
					]
				)
			}
			.opacity(hasAppeared ? 1 : 0)
			.animation(entrance(delay: 0), value: hasAppeared)

			window
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(localized: .appUI.onboarding.defaultBrowser.illustration))
		.accessibilityAddTraits(.isImage)
		.onAppear { hasAppeared = true }
	}

	private var window: some View {
		let shape: RoundedRectangle = .init(cornerRadius: 12, style: .continuous)

		return HStack(spacing: 0) {
			sidebar
				.frame(width: 140)
				.frame(maxHeight: .infinity, alignment: .top)
				.background(.quaternary.opacity(0.6))

			page
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				.opacity(hasAppeared ? 1 : 0)
				.offset(x: hasAppeared || reduceMotion ? 0 : 16)
				.animation(entrance(delay: 0.25), value: hasAppeared)
		}
		.frame(width: 440, height: 230)
		.background(.background, in: shape)
		.clipShape(shape)
		.overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
		.shadow(color: .black.opacity(0.12), radius: 16, y: 6)
	}

	private var sidebar: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 5) {
				ForEach([Color.red, .yellow, .green], id: \.self) { color in
					Circle()
						.fill(color.opacity(0.85))
						.frame(width: 7, height: 7)
				}
			}
			.padding(.bottom, 6)

			Label {
				Text(localized: .appUI.onboarding.defaultBrowser.sample.newTab)
			} icon: {
				Image(systemName: "plus")
			}
			.foregroundStyle(.secondary)

			Label {
				Text(localized: .appUI.onboarding.defaultBrowser.sample.title)
			} icon: {
				Image(systemName: "doc.text")
			}
			.padding(.vertical, 4)
			.padding(.horizontal, 6)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(.background, in: .rect(cornerRadius: 6, style: .continuous))
			.padding(.horizontal, -6)
			.opacity(hasAppeared ? 1 : 0)
			.animation(entrance(delay: 0.15), value: hasAppeared)
		}
		.font(.system(size: 10))
		.labelStyle(.titleAndIcon)
		.padding(12)
	}

	private var page: some View {
		VStack(alignment: .leading, spacing: 6) {
			Label {
				Text(verbatim: "notes.example.com")
			} icon: {
				Image(systemName: "doc.text")
			}
			.font(.system(size: 9))
			.foregroundStyle(.secondary)

			Text(localized: .appUI.onboarding.defaultBrowser.sample.title)
				.font(.system(size: 15, weight: .semibold))
				.padding(.top, 4)

			Text(localized: .appUI.onboarding.defaultBrowser.sample.shared)
				.font(.system(size: 9))
				.foregroundStyle(.secondary)

			Text(localized: .appUI.onboarding.defaultBrowser.sample.summary)
				.font(.system(size: 10))
				.padding(.top, 8)

			VStack(alignment: .leading, spacing: 4) {
				bullet(.appUI.onboarding.defaultBrowser.sample.item1)
				bullet(.appUI.onboarding.defaultBrowser.sample.item2)
				bullet(.appUI.onboarding.defaultBrowser.sample.item3)
			}
			.font(.system(size: 10))
		}
		.padding(16)
	}

	private func bullet(_ text: _XCStringResource) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Text(verbatim: "•")
			Text(localized: text)
		}
	}

	private func entrance(delay: Double) -> Animation {
		reduceMotion
		? .easeOut(duration: 0.3).delay(delay)
		: .spring(duration: 0.6, bounce: 0.2).delay(delay)
	}
}

/// An app icon drawn from a symbol on a gradient tile, standing in for Mail and Messages.
private struct OnboardingAppTile: View {
	internal let symbol: String
	internal let colors: [Color]

	internal var body: some View {
		let shape: RoundedRectangle = .init(cornerRadius: 10, style: .continuous)

		shape
			.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
			.frame(width: 44, height: 44)
			.overlay {
				Image(systemName: symbol)
					.font(.system(size: 20, weight: .medium))
					.foregroundStyle(.white)
			}
			.shadow(color: .black.opacity(0.15), radius: 4, y: 2)
	}
}
