import AppKit
import BrowserCore
import SwiftUI

/// What a refused App Links handler (DEV-857, DEV-862) gets wrong, naming the rule it breaks.
public func appLinkErrorMessage(_ error: AppLinkError) -> String {
	switch error {
	case .invalidScheme: String.localized(.appUI.appLinks.invalid.scheme)
	case .reservedScheme: String.localized(.appUI.appLinks.invalid.reservedScheme)
	case .invalidHost: String.localized(.appUI.appLinks.invalid.host)
	case .invalidPath: String.localized(.appUI.appLinks.invalid.path)
	case .invalidDefinition: String.localized(.appUI.appLinks.invalidDefinition)
	case .malformed: String.localized(.appUI.appLinks.invalid.malformed)
	case .schemeMismatch: String.localized(.appUI.appLinks.invalid.schemeMismatch)
	case .controlCharacters: String.localized(.appUI.appLinks.invalid.controlCharacters)
	case .tooLong: String.localized(.appUI.appLinks.invalid.tooLong)
	}
}

/// An app's Finder icon at `path`, or nil when nothing is there. Kept once looked up, since a
/// picker lists many apps on every pass.
@MainActor
public func appLinkIcon(path: String) -> NSImage? {
	if let icon = AppLinkIconCache.icons[path] { return icon }
	guard FileManager.default.fileExists(atPath: path) else { return nil }
	let icon = NSWorkspace.shared.icon(forFile: path)
	icon.size = .init(width: 32, height: 32)
	AppLinkIconCache.icons[path] = icon
	return icon
}

@MainActor
private enum AppLinkIconCache {
	internal static var icons: [String: NSImage] = [:]
}

/// The app picker's button face (DEV-862): a rounded rectangle as tall as the fields beside it,
/// with a plus in a circle until an app is picked, then that app's icon. It never shows an app
/// that wasn't picked.
public struct AppLinkAppLabel: View {
	private let name: String?
	private let icon: NSImage?

	/// `name` is the picked app's, for VoiceOver; nil before one is picked.
	public init(
		name: String?,
		icon: NSImage?
	) {
		self.name = name
		self.icon = icon
	}

	public var body: some View {
		Group {
			if name != nil, let icon {
				Image(nsImage: icon)
					.resizable()
					.frame(width: 30, height: 30)
			} else if name != nil {
				Image(systemName: "app.dashed")
					.font(.system(size: 22))
					.foregroundStyle(.secondary)
			} else {
				Image(systemName: "plus.circle")
					.font(.system(size: 20, weight: .regular))
					.foregroundStyle(.secondary)
			}
		}
		.frame(width: 52, height: 52)
		.background(SettingsGroupMetrics.fill, in: ArxControlShape())
		.overlay {
			ArxControlShape().strokeBorder(SettingsGroupMetrics.hairline, lineWidth: 0.5)
		}
		.contentShape(ArxControlShape())
		.accessibilityElement()
		.accessibilityLabel(Text(localized: .appUI.appLinks.app))
		.accessibilityValue(name ?? String.localized(.appUI.appLinks.chooseApp))
	}
}

/// A Run script route's script (DEV-862): the field with the example as ghost text, Tab or →
/// in the empty field to use it (with a hint while it's focused and empty), then one row with
/// "The link is $1. Quote it." and Test and Remove, and a failure on its own line below,
/// wrapped, never cut off.
public struct AppLinkScriptField<Status: View>: View {
	@Binding
	private var script: String

	private let example: String
	private let error: String?
	private let isTestDisabled: Bool
	private let onUseExample: () -> Void
	private let onCommit: () -> Void
	private let onTest: () -> Void
	private let onRemove: (() -> Void)?
	private let status: Status

	@FocusState
	private var isFocused: Bool

	/// `status` sits before Test, such as Testing… or Succeeded. `onRemove` nil has no Remove.
	public init(
		script: Binding<String>,
		example: String,
		error: String?,
		isTestDisabled: Bool,
		onUseExample: @escaping () -> Void,
		onCommit: @escaping () -> Void,
		onTest: @escaping () -> Void,
		onRemove: (() -> Void)?,
		@ViewBuilder status: () -> Status
	) {
		self._script = script
		self.example = example
		self.error = error
		self.isTestDisabled = isTestDisabled
		self.onUseExample = onUseExample
		self.onCommit = onCommit
		self.onTest = onTest
		self.onRemove = onRemove
		self.status = status()
	}

	private var isEmpty: Bool {
		script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			TextField(example, text: $script, prompt: Text(verbatim: example), axis: .vertical)
				.font(.callout.monospaced())
				.textFieldStyle(.arx)
				.lineLimit(1...6)
				.focused($isFocused)
				.onSubmit(onCommit)

				// Only while the ghost text shows: otherwise Tab moves focus as usual.
				.onKeyPress(.tab) { useExample() }
				.onKeyPress(.rightArrow) { useExample() }
				.onChange(of: isFocused) { _, focused in
					if !focused { onCommit() }
				}
			if isFocused, isEmpty {
				Text(localized: .appUI.appLinks.useExample)
					.font(.caption)
					.foregroundStyle(.tertiary)
			}
			HStack(spacing: 8) {
				Text(localized: .appUI.appLinks.scriptHint)
					.font(.caption)
					.foregroundStyle(.secondary)
				Spacer(minLength: 8)
				status
				Button(String.localized(.appUI.appLinks.test)) {
					onCommit()
					onTest()
				}
				.buttonStyle(.arx(.secondary, size: .small))
				.disabled(isTestDisabled || isEmpty)
				if let onRemove {
					Button(String.localized(.appUI.appLinks.removeOverride), action: onRemove)
						.buttonStyle(.arx(.secondary, size: .small))
				}
			}
			if let error {
				Text(error)
					.font(.caption)
					.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: .infinity, alignment: .leading)
					.textSelection(.enabled)
			}
		}
	}

	private func useExample() -> KeyPress.Result {
		guard isEmpty else { return .ignored }
		script = example
		onUseExample()
		return .handled
	}
}

/// One of an App Links handler's text fields.
public enum AppLinkField: Hashable, Sendable {
	case name
	case scheme
	case host
	case path
}

/// An App Links handler's own fields (DEV-862): the app picker, labelled Name, Scheme, Host and
/// Path, and under them the links it catches or the scheme rule it breaks, as you type.
public struct AppLinkFields<Picker: View, Accessory: View>: View {
	public typealias Field = AppLinkField

	@Binding
	private var name: String

	@Binding
	private var scheme: String

	@Binding
	private var host: String

	@Binding
	private var path: String

	private let error: AppLinkError?
	private let onEditingChanged: (Field, Bool) -> Void
	private let onSubmit: () -> Void
	private let picker: Picker
	private let accessory: Accessory

	/// `error` is the last refused save; a scheme that breaks a rule as typed shows first.
	/// `accessory` follows the fields on the first line, such as the on switch and Remove.
	public init(
		name: Binding<String>,
		scheme: Binding<String>,
		host: Binding<String>,
		path: Binding<String>,
		error: AppLinkError? = nil,
		onEditingChanged: @escaping (Field, Bool) -> Void = { _, _ in },
		onSubmit: @escaping () -> Void = {},
		@ViewBuilder picker: () -> Picker,
		@ViewBuilder accessory: () -> Accessory
	) {
		self._name = name
		self._scheme = scheme
		self._host = host
		self._path = path
		self.error = error
		self.onEditingChanged = onEditingChanged
		self.onSubmit = onSubmit
		self.picker = picker()
		self.accessory = accessory()
	}

	/// The rule the typed scheme breaks, else the refused save's.
	private var problem: AppLinkError? {
		let normalized = AppLinkHandler.normalizedScheme(scheme)
		if !normalized.isEmpty, let problem = AppLinkHandler.schemeProblem(normalized) { return problem }
		return error
	}

	private var example: String? {
		AppLinkHandler.example(
			scheme: scheme,
			host: host.isEmpty ? nil : host,
			pathPrefix: path.isEmpty ? nil : path
		)
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				picker
				field(.name, String.localized(.appUI.appLinks.name), text: $name, prompt: "Claude")
				field(.scheme, String.localized(.appUI.appLinks.scheme), text: $scheme, prompt: "claude")
				accessory
			}
			HStack(spacing: 8) {
				field(.host, String.localized(.appUI.appLinks.host), text: $host, prompt: String.localized(.appUI.appLinks.anyHost))
				field(.path, String.localized(.appUI.appLinks.path), text: $path, prompt: String.localized(.appUI.appLinks.anyPath))
			}
			if let problem {
				Text(appLinkErrorMessage(problem))
					.font(.caption)
					.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
			} else if let example {
				Text(localized: .appUI.appLinks.catches(example))
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
		}
	}

	private func field(
		_ id: Field,
		_ title: String,
		text: Binding<String>,
		prompt: String
	) -> some View {
		SettingsTextField(
			title,
			text: text,
			prompt: prompt,
			onEditingChanged: { onEditingChanged(id, $0) },
			onSubmit: onSubmit
		)
		.frame(maxWidth: .infinity)
	}
}

extension AppLinkFields where Accessory == EmptyView {
	public init(
		name: Binding<String>,
		scheme: Binding<String>,
		host: Binding<String>,
		path: Binding<String>,
		error: AppLinkError? = nil,
		onEditingChanged: @escaping (Field, Bool) -> Void = { _, _ in },
		onSubmit: @escaping () -> Void = {},
		@ViewBuilder picker: () -> Picker
	) {
		self.init(
			name: name,
			scheme: scheme,
			host: host,
			path: path,
			error: error,
			onEditingChanged: onEditingChanged,
			onSubmit: onSubmit,
			picker: picker,
			accessory: { EmptyView() }
		)
	}
}
