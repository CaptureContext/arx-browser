import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// The corner rule and size mapping Arx's controls share.
internal struct ArxControlsTests {
	@Test
	internal func theCornerRadiusIsAFixedShareOfTheSmallerSide() {
		#expect(ArxControlShape.cornerRadius(for: .init(width: 120, height: 28)) == 28 * 0.28)
		#expect(ArxControlShape.cornerRadius(for: .init(width: 20, height: 34)) == 20 * 0.28)
		#expect(ArxControlShape.cornerRadius(for: .zero) == 0)
		#expect(ArxControlShape.cornerRadius(forSide: 44) == 44 * 0.28)
		#expect(ArxControlShape.cornerRadius(forSide: -4) == 0)
	}

	/// DEV-749: the chrome's control metrics come from the rule rather than fixed numbers.
	@Test
	internal func chromeControlRadiiFollowTheRule() {
		#expect(BrowserMetrics.Toolbar.buttonCornerRadius == BrowserMetrics.Toolbar.buttonSize * 0.28)
		// The sidebar's URL bar rounds like the Favorites under it (DEV-1252); other heights keep the rule.
		#expect(BrowserMetrics.URLBar.cornerRadius == BrowserMetrics.Favorites.cornerRadius)
		#expect(BrowserMetrics.URLBar.cornerRadius(forHeight: BrowserMetrics.LittleArx.addressHeight) == BrowserMetrics.LittleArx.addressHeight * 0.28)
		// The sidebar's rows are a little rounder than the rule (DEV-1310).
		#expect(BrowserMetrics.Row.cornerRadius == 12)
		#expect(BrowserMetrics.Row.cornerRadius > BrowserMetrics.Row.height * 0.28)
		#expect(BrowserMetrics.Favorites.cornerRadius == BrowserMetrics.Favorites.tileHeight * 0.28)
		#expect(BrowserMetrics.FindBar.cornerRadius == ArxRaisedShape.cornerRadius(forSide: BrowserMetrics.FindBar.height))
		#expect(BrowserMetrics.Library.fieldCornerRadius == BrowserMetrics.Library.fieldHeight * 0.28)
	}

	@Test
	internal func controlSizesFollowSwiftUIsControlSize() {
		#expect(ArxControlSize(.mini) == .small)
		#expect(ArxControlSize(.small) == .small)
		#expect(ArxControlSize(.regular) == .regular)
		#expect(ArxControlSize(.large) == .large)
		#expect(ArxControlSize(.extraLarge) == .large)
	}

	@Test
	internal func largerSizesAreTaller() {
		#expect(ArxControlSize.small.height < ArxControlSize.regular.height)
		#expect(ArxControlSize.regular.height < ArxControlSize.large.height)
	}

	/// DEV-797: raised toolbar controls are squircles, rounder than other controls.
	@Test
	internal func raisedControlsAreRounderSquircles() {
		#expect(ArxRaisedShape.cornerRadius(forSide: 36) == 36 * 0.34)
		#expect(ArxRaisedShape.cornerRadius(forSide: -1) == 0)
		#expect(ArxRaisedShape.cornerRatio > ArxControlShape.cornerRatio)
	}

	/// DEV-797: only focus moved by Tab shows a ring; focus a sheet hands out as it opens doesn't.
	@MainActor
	@Test
	internal func onlyAKeyboardMoveShowsTheFocusRing() {
		ArxKeyboardFocus.reset(navigatedAt: nil)
		#expect(!ArxKeyboardFocus.isNavigating)
		ArxKeyboardFocus.reset(navigatedAt: .now)
		#expect(ArxKeyboardFocus.isNavigating)
		ArxKeyboardFocus.reset(navigatedAt: .now.addingTimeInterval(-2))
		#expect(!ArxKeyboardFocus.isNavigating)
		ArxKeyboardFocus.reset(navigatedAt: nil)
	}
}

/// Writes offscreen PNGs of Arx's controls in every state, light and dark, for visual review,
/// when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct ArxControlsSnapshotTests {
	private enum State: String, CaseIterable {
		case normal
		case hover
		case pressed
		case disabled
		case focused

		internal var override: ArxControlStateOverride {
			switch self {
			case .normal, .disabled: .init()
			case .hover: .init(isHovered: true)
			case .pressed: .init(isPressed: true)
			case .focused: .init(isFocused: true)
			}
		}
	}

	@Test(arguments: [false, true])
	internal func controls(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = VStack(alignment: .leading, spacing: 14) {
			ForEach(State.allCases, id: \.self) { state in
				HStack(spacing: 12) {
					Text(state.rawValue)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.frame(width: 60, alignment: .leading)
					Button {} label: { ArxButtonLabel("Quit", keyHint: .return) }
						.buttonStyle(.arx(.primary))
					Button {} label: { ArxButtonLabel("Cancel", keyHint: .escape) }
						.buttonStyle(.arx)
					Button("Remove", role: .destructive) {}
						.buttonStyle(.arx)
					Button("Small") {}
						.buttonStyle(.arx(size: .small))
					Button {} label: { ArxButtonLabel("Large", systemImage: "plus") }
						.buttonStyle(.arx(.primary, size: .large))
					TextField("Address", text: .constant(""), prompt: Text(verbatim: "example.com"))
						.textFieldStyle(.arx)
						.frame(width: 150)
					TextField("Search", text: .constant("arx.dev"))
						.textFieldStyle(.arx(systemImage: "magnifyingglass"))
						.frame(width: 150)
					Button {} label: { Image(systemName: "minus.circle") }
						.buttonStyle(.arx(.plain, size: .small))
					ArxDropdown(
						"Open in",
						selection: .constant(1),
						options: [.init(id: 1, title: "Window", symbol: "macwindow"), .init(id: 2, title: "Little Arx")]
					)
					Button {} label: { Image(systemName: "xmark") }
						.buttonStyle(.arxRaised(size: .large))
					ArxRaisedGroup {
						Button {} label: { Image(systemName: "ellipsis") }
							.buttonStyle(.arxRaised(.item))
						Button {} label: { Image(systemName: "list.bullet") }
							.buttonStyle(.arxRaised(.item, isSelected: true))
					}
					.controlSize(.large)
				}
				.disabled(state == .disabled)
				.arxControlState(state.override)
			}

			// A modal's button row, in every state, on the modal background.
			ForEach(State.allCases, id: \.self) { state in
				HStack(spacing: ArxModalMetrics.buttonSpacing) {
					Text(state.rawValue)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.frame(width: 60, alignment: .leading)
					ArxModalButton.cancel {}
					ArxModalButton("Create") {}
					ArxModalButton("Remove", role: .destructive) {}
					ArxModalButton("Delete", prominence: .destructive, key: nil) {}
				}
				.disabled(state == .disabled)
				.arxControlState(state.override)
			}
			ArxSuggestionList(
				[
					ArxSuggestion(id: 1, title: "Window", symbol: "macwindow"),
					ArxSuggestion(id: 2, title: "Little Arx", symbol: "rectangle.inset.topright.filled"),
					ArxSuggestion(id: 3, title: "Ask Every Time", symbol: "questionmark.circle"),
				],
				highlighted: 2,
				checked: 1
			) { _ in }
		}
		.padding(20)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "arx-controls-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// Settings drill-down rows (DEV-773) at rest, hovered and pressed, on one card, the last
	/// with its own controls on the trailing side.
	@Test(arguments: [false, true])
	internal func settingsRows(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let states: [State] = [.normal, .hover, .pressed]
		let view = SettingsSection("Profile") {
			ForEach(states, id: \.self) { state in
				Button {} label: {
					HStack(spacing: 10) {
						Image(systemName: "hand.raised")
							.foregroundStyle(.secondary)
							.frame(width: 20)
						Text(verbatim: "Site Settings (\(state.rawValue))")
						Spacer(minLength: 12)
						Image(systemName: "chevron.right")
							.font(.system(size: 11, weight: .semibold))
							.foregroundStyle(.tertiary)
					}
					.settingsGroupRow()
					.contentShape(.rect)
				}
				.buttonStyle(.settingsGroupRow)
				.arxControlState(state.override)
			}
			HStack(spacing: 8) {
				Button {} label: {
					HStack {
						Text(verbatim: "Rule (hover)")
						Spacer(minLength: 12)
					}
					.settingsGroupRow()
					.contentShape(.rect)
				}
				.buttonStyle(.settingsGroupRow(edges: .leading))
				.arxControlState(.init(isHovered: true))
				Button {} label: { Image(systemName: "arrow.up") }
					.buttonStyle(.arx(.plain, size: .small))
				Toggle("On", isOn: .constant(true))
					.toggleStyle(.switch)
					.controlSize(.small)
					.labelsHidden()
			}
		}
		.frame(width: 420)
		.padding(20)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "settings-rows-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
