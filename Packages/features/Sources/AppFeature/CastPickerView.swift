import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import SwiftUI
import _ComposableArchitecture

/// Puts a tab's Cast picker (DEV-927) on its window as a sheet.
internal struct CastPickerPresentation: ViewModifier {
	@Bindable
	private var store: StoreOf<AppFeature>

	private let windowID: UUID

	internal init(
		store: StoreOf<AppFeature>,
		windowID: UUID
	) {
		self.store = store
		self.windowID = windowID
	}

	internal func body(content: Content) -> some View {
		let isPresented = store.castPicker?.windowID == windowID
		content.sheet(
			isPresented: Binding(
				get: { isPresented },
				set: { presented in

					// The sheet closing on its own (Escape) is Done.
					if !presented, store.castPicker?.windowID == windowID {
						store.send(.castPicker(.ui(.doneButtonTapped)))
					}
				}
			)
		) {
			if let child = store.scope(state: \.castPicker, action: \.castPicker) {
				CastPickerView(store: child)
			}
		}
	}
}

/// Arx's Cast picker, in the style of its other prompts: what casts, the devices found as
/// rows (a click casts, or replaces what the device casts), Stop on the ones casting, and
/// Done. A device that takes both the site's video and the tab offers the tab in its menu.
internal struct CastPickerView: View {
	private let store: StoreOf<CastPicker>

	internal init(store: StoreOf<CastPicker>) {
		self.store = store
	}

	internal var body: some View {
		VStack(spacing: 0) {
			VStack(spacing: 10) {
				Image(systemName: "tv.badge.wifi")
					.resizable()
					.scaledToFit()
					.padding(8)
					.frame(width: 56, height: 56)
					.foregroundStyle(.secondary)
					.accessibilityHidden(true)
				Text(title)
					.font(.system(size: 17, weight: .semibold))
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
					.accessibilityAddTraits(.isHeader)
			}
			.frame(maxWidth: .infinity)
			.padding(.bottom, 14)

			devices
				.frame(maxWidth: .infinity, minHeight: 120, alignment: .top)

			Spacer(minLength: 18)

			AppLinkPromptButton(
				String.localized(.appUI.cast.done),
				prominence: .primary,
				keyHint: .escape
			) {
				store.send(.ui(.doneButtonTapped))
			}
			.keyboardShortcut(.cancelAction)
		}
		.padding(ArxModalMetrics.contentPadding)
		.frame(width: 360)
		.background(ArxModalMetrics.background)
	}

	private var title: String {
		store.picker.source.isEmpty ? String.localized(.appUI.cast.title) : store.picker.source
	}

	@ViewBuilder
	private var devices: some View {
		if store.picker.isLocalNetworkDenied {
			VStack(spacing: 10) {
				message(String.localized(.appUI.cast.localNetworkDenied))
				AppLinkPromptButton(String.localized(.appUI.cast.openPrivacySettings)) {
					Self.openLocalNetworkSettings()
				}
			}
		} else if store.picker.devices.isEmpty {
			VStack(spacing: 10) {
				ProgressView()
					.controlSize(.small)
					.accessibilityHidden(true)
				message(String.localized(.appUI.cast.searching))
			}
			.frame(maxWidth: .infinity)
			.padding(.top, 12)
		} else {
			ScrollView {
				VStack(spacing: 4) {
					ForEach(store.picker.devices) { device in
						CastDeviceRow(
							device: device,
							onChoose: { store.send(.ui(.deviceChosen(device.id, $0))) },
							onStop: { route in store.send(.ui(.stopButtonTapped(route: route))) }
						)
					}
				}
			}
			.frame(maxHeight: 280)
		}
	}

	private func message(_ text: String) -> some View {
		Text(text)
			.font(.callout)
			.foregroundStyle(.secondary)
			.multilineTextAlignment(.center)
			.fixedSize(horizontal: false, vertical: true)
			.frame(maxWidth: .infinity)
	}

	/// System Settings › Privacy & Security › Local Network.
	private static func openLocalNetworkSettings() {
		guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
		else { return }

		NSWorkspace.shared.open(url)
	}
}

/// One device: its kind, name and what it does now, and Stop while it casts.
private struct CastDeviceRow: View {
	internal let device: BrowserCastPicker.Device
	internal let onChoose: (BrowserCastPicker.Device.Mode?) -> Void
	internal let onStop: (String) -> Void

	@SwiftUI.State
	private var hovered: Bool = false

	internal var body: some View {
		HStack(spacing: 8) {
			// A real button, so Tab reaches it and Space or Return casts.
			Button { onChoose(nil) } label: {
				HStack(spacing: 10) {
					Image(systemName: symbol)
						.font(.system(size: 15))
						.frame(width: 22)
						.foregroundStyle(device.state == .connected ? Color.accentColor : .secondary)
						.accessibilityHidden(true)
					VStack(alignment: .leading, spacing: 1) {
						Text(device.name)
							.lineLimit(1)
							.truncationMode(.middle)
						if let detail {
							Text(detail)
								.font(.caption)
								.foregroundStyle(device.issue == nil ? Color.secondary : .red)
								.lineLimit(2)
						}
					}
					Spacer(minLength: 8)
					if device.state == .connecting || device.state == .disconnecting {
						ProgressView()
							.controlSize(.small)
							.accessibilityHidden(true)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.contentShape(ArxControlShape())
			}
			.buttonStyle(.plain)
			.disabled(!device.canChoose)
			.contextMenu {
				// The tab instead of the site's own video, when the device takes both.
				if device.issue == nil, device.modes.contains(.presentation), device.modes.contains(.tab) {
					Button(String.localized(.appUI.cast.castTabInstead)) { onChoose(.tab) }
				}
			}
			.accessibilityElement(children: .combine)
			if device.state == .connected, let route = device.route {
				Button(String.localized(.appUI.cast.stop)) { onStop(route) }
					.buttonStyle(.arxModal(.secondary))
			}
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
		.background(hovered && device.canChoose ? Color.primary.opacity(0.06) : .clear, in: ArxControlShape())
		.opacity(device.canChoose || device.state == .connected ? 1 : 0.5)
		.onHover { hovered = $0 }
	}

	private var symbol: String {
		switch device.kind {
		case .audio: "hifispeaker"
		case .audioGroup: "hifispeaker.2"
		case .display: "display"
		case .cast, .generic: "tv"
		}
	}

	/// The problem first, then what's happening, then what it casts.
	private var detail: String? {
		if let issue = device.issue { return issue }
		switch device.state {
		case .connecting: return String.localized(.appUI.cast.connecting)
		case .disconnecting: return String.localized(.appUI.cast.stopping)
		case .unavailable: return String.localized(.appUI.cast.unavailable)
		case .connected: return device.status ?? String.localized(.appUI.cast.casting)
		case .available: return device.status
		}
	}
}
