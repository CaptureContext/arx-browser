import AppKit
import AppUI
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

extension View {
	/// Shows the system share sheet with the identity card as an image, with Copy and Save added.
	internal func identityCardSharing(
		isPresented: Bool,
		style: IdentityCardStyle,
		stats: ArxIdentityCard.Stats,
		member: MemberNumber?,
		memberSince: Date?,
		onFinish: @escaping () -> Void
	) -> some View {
		background {
			IdentityCardSharePicker(
				isPresented: isPresented,
				style: style,
				stats: stats,
				member: member,
				memberSince: memberSince,
				onFinish: onFinish
			)
		}
	}
}

/// Anchors `NSSharingServicePicker` to the card's frame.
private struct IdentityCardSharePicker: NSViewRepresentable {
	internal let isPresented: Bool
	internal let style: IdentityCardStyle
	internal let stats: ArxIdentityCard.Stats
	internal let member: MemberNumber?
	internal let memberSince: Date?
	internal let onFinish: () -> Void

	internal func makeCoordinator() -> Coordinator { Coordinator() }

	internal func makeNSView(context: Context) -> NSView { NSView() }

	internal func updateNSView(
		_ view: NSView,
		context: Context
	) {
		context.coordinator.onFinish = onFinish
		guard isPresented, !context.coordinator.isShowing else { return }
		guard let image = ArxIdentityCard.image(
			style: style,
			stats: stats,
			member: member,
			memberSince: memberSince
		) else {
			onFinish()
			return
		}
		context.coordinator.isShowing = true
		let picker = NSSharingServicePicker(items: [image])
		picker.delegate = context.coordinator

		// The picker anchors to a laid-out view; wait for this update to finish.
		DispatchQueue.main.async {
			picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
		}
	}

	@MainActor
	internal final class Coordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate {
		internal var isShowing: Bool = false
		internal var onFinish: () -> Void = {}

		internal func sharingServicePicker(
			_ picker: NSSharingServicePicker,
			sharingServicesForItems items: [Any],
			proposedSharingServices proposed: [NSSharingService]
		) -> [NSSharingService] {
			guard let image = items.first as? NSImage else { return proposed }
			let copy = NSSharingService(
				title: String.localized(.appUI.settings.identity.copy),
				image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage(),
				alternateImage: nil
			) {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.writeObjects([image])
			}
			let save = NSSharingService(
				title: String.localized(.appUI.settings.identity.save),
				image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil) ?? NSImage(),
				alternateImage: nil
			) {
				Self.save(image)
			}
			return [copy, save] + proposed
		}

		internal func sharingServicePicker(
			_ picker: NSSharingServicePicker,
			didChoose service: NSSharingService?
		) {
			isShowing = false
			onFinish()
		}

		@MainActor
		private static func save(_ image: NSImage) {
			let panel = NSSavePanel()
			panel.allowedContentTypes = [.png]
			panel.nameFieldStringValue = String.localized(.appUI.settings.identity.fileName) + ".png"
			guard
				panel.runModal() == .OK,
				let url = panel.url,
				let tiff = image.tiffRepresentation,
				let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
			else { return }

			try? png.write(to: url, options: .atomic)
		}
	}
}
