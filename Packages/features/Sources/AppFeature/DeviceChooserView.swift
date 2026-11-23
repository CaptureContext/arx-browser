import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import SwiftUI
import _ComposableArchitecture

/// Puts a page's device request (DEV-905) on its window as a sheet.
internal struct DeviceChooserPresentation: ViewModifier {
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
		let isPresented = store.deviceChooser?.windowID == windowID
		content.sheet(
			isPresented: Binding(
				get: { isPresented },
				set: { presented in

					// The sheet closing on its own (Escape) is Cancel.
					if !presented, store.deviceChooser?.windowID == windowID {
						store.send(.deviceChooser(.ui(.cancelButtonTapped)))
					}
				}
			)
		) {
			if let child = store.scope(state: \.deviceChooser, action: \.deviceChooser) {
				DeviceChooserView(store: child)
			}
		}
	}
}

/// The devices that match the page's request, in a list, with Connect, Cancel and, for
/// Bluetooth, Scan Again. Double-clicking a device connects it.
internal struct DeviceChooserView: View {
	@Bindable
	private var store: StoreOf<DeviceChooserPrompt>

	internal init(store: StoreOf<DeviceChooserPrompt>) {
		self.store = store
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(store.chooser.title)
				.font(.headline)
				.fixedSize(horizontal: false, vertical: true)

			devices
				.frame(minHeight: 180)

			HStack {
				if store.chooser.canScanAgain {
					Button(String.localized(.appUI.deviceChooser.scanAgain)) {
						store.send(.ui(.scanAgainButtonTapped))
					}
					.disabled(store.chooser.isScanning || store.chooser.adapterIsOff)
				}
				if store.chooser.isScanning {
					ProgressView()
						.controlSize(.small)
						.accessibilityLabel(Text(localized: .appUI.deviceChooser.searching))
				}
				Spacer()
				Button(String.localized(.appUI.deviceChooser.cancel)) {
					store.send(.ui(.cancelButtonTapped))
				}
				.keyboardShortcut(.cancelAction)
				Button(String.localized(.appUI.deviceChooser.connect)) {
					store.send(.ui(.connectButtonTapped))
				}
				.keyboardShortcut(.defaultAction)
				.disabled(!store.canConnect)
			}
		}
		.padding(20)
		.frame(width: 420)
	}

	@ViewBuilder
	private var devices: some View {
		if store.chooser.adapterIsOff {
			message(String.localized(.appUI.deviceChooser.adapterOff))
		} else if store.chooser.options.isEmpty {
			message(String.localized(
				store.chooser.isScanning ? .appUI.deviceChooser.searching : .appUI.deviceChooser.noDevices
			))
		} else {
			List(selection: Binding(
				get: { store.selection },
				set: { store.send(.ui(.selectionChanged($0))) }
			)) {
				ForEach(Array(store.chooser.options.enumerated()), id: \.offset) { index, option in
					row(option)
						.tag(index)
				}
			}
			.contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { indices in
				store.send(.ui(.selectionChanged(indices)))
				store.send(.ui(.connectButtonTapped))
			}
			.listStyle(.bordered)
		}
	}

	private func row(_ option: BrowserDeviceChooser.Option) -> some View {
		HStack(spacing: 8) {
			Text(option.name)
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer(minLength: 8)
			if option.isConnected {
				Text(localized: .appUI.deviceChooser.connected)
					.foregroundStyle(.secondary)
			} else if option.isPaired {
				Text(localized: .appUI.deviceChooser.paired)
					.foregroundStyle(.secondary)
			}
			if let signal = option.signal {
				Image(systemName: "cellularbars", variableValue: Double(signal) / 4)
					.foregroundStyle(.secondary)
					.accessibilityHidden(true)
			}
		}
	}

	private func message(_ text: String) -> some View {
		Text(text)
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.multilineTextAlignment(.center)
			.background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
	}
}
