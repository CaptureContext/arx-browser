import AppKit
import BrowserCore
import SwiftUI

/// The URL bar's site menu (DEV-633). Actions that open something
/// else (share, capture, Settings, a new tab) close the panel first. Main windows, Little Arx and
/// Page PiP share it, each showing the items its window allows (DEV-1257).
public struct SiteMenuPanel: View {
	private let menu: SiteMenu
	private let send: @MainActor (SiteMenuAction) -> Void
	private let dismiss: () -> Void

	@SwiftUI.State
	private var isHoveringExtensions: Bool

	/// The widest pop-up's own width, so every pop-up can share it.
	@SwiftUI.State
	private var widestPicker: CGFloat

	/// The key under the pointer, and the one whose tooltip shows (DEV-1333).
	@SwiftUI.State
	private var hoveredKey: SiteMenu.Key.ID?

	@SwiftUI.State
	private var keyTooltip: SiteMenu.Key.ID?

	public init(
		menu: SiteMenu,
		send: @escaping @MainActor (SiteMenuAction) -> Void,
		dismiss: @escaping () -> Void
	) {
		self.menu = menu
		self.send = send
		self.dismiss = dismiss
		self._isHoveringExtensions = .init(initialValue: false)
		self._widestPicker = .init(initialValue: 0)
		self._hoveredKey = .init(initialValue: nil)
		self._keyTooltip = .init(initialValue: nil)
	}

	/// `tooltip` shows that key's tooltip from the start, as a snapshot does.
	internal init(
		menu: SiteMenu,
		tooltip: SiteMenu.Key.ID?
	) {
		self.init(menu: menu, send: { _ in }, dismiss: {})
		self._keyTooltip = .init(initialValue: tooltip)
	}

	/// One grid for the menu (DEV-1333): eight extension tiles a row, and a key spans two.
	internal enum Grid {
		/// An extension tile's side, and the grid's column.
		internal static let column: CGFloat = 32
		internal static let spacing: CGFloat = 6
		internal static let columns: Int = 8

		/// A key spans two columns and the gap between them.
		internal static let keyWidth: CGFloat = column * 2 + spacing
		internal static let keyHeight: CGFloat = 40

		/// The content's width: eight columns.
		internal static let width: CGFloat = column * CGFloat(columns) + spacing * CGFloat(columns - 1)
		internal static let padding: CGFloat = 14
	}

	/// The grid and its padding: 326 points (DEV-1333). The rows fit it in every shipped language
	/// with their short pop-ups; a long permission name wraps to a second line instead of cutting
	/// off, as Spanish, Russian and Ukrainian "Pop-ups and redirects" do.
	internal static let width: CGFloat = Grid.width + Grid.padding * 2

	/// Pop-ups share one width, never narrower than this, so their edges line up.
	internal static let minimumPickerWidth: CGFloat = 64

	public var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			actions

				// Its tooltips hang over the section under it.
				.zIndex(1)

			if let extensions = menu.extensions, menu.shows(.extensions) {
				extensionsSection(extensions)
				if let removing = menu.removingExtension {
					removalSection(removing)
				}
			}

			if showsPermissions, let permissions = menu.permissions {
				permissionsSection(permissions)
			}

			if menu.shows(.translation), let translation = menu.translation {
				translationSection(translation)
			}

			if menu.shows(.devices), let devices = menu.devices, !devices.isEmpty {
				devicesSection(devices)
			}

			if menu.shows(.hiddenElements), let hiddenElements = menu.hiddenElements, !hiddenElements.isEmpty {
				hiddenElementsSection(hiddenElements)
			}

			// Unread badges is a row of Site Settings; alone only where the menu lists no permissions.
			if !showsPermissions, menu.shows(.unreadBadges), let unreadBadges = menu.unreadBadges {
				unreadBadgesRow(unreadBadges)
			}

			if let clearing = menu.clearing {
				clearingSection(clearing)
			} else if let notice = menu.notice {
				noticeRow(notice)
			}

			Divider()

			connectionRow
		}
		.padding(Grid.padding)
		.frame(width: Self.width, alignment: .leading)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.url.siteInformation))

		// No ring on Share until the keyboard asks for one.
		.popoverOpensWithoutFocus()
	}

	// MARK: - Actions

	/// The keys, two rows of four (DEV-1333): hovering one names it in a tooltip under it.
	private var actions: some View {
		VStack(alignment: .leading, spacing: 8) {
			VStack(alignment: .leading, spacing: Grid.spacing) {
				ForEach(Array(menu.keyRows.enumerated()), id: \.offset) { _, row in
					HStack(spacing: Grid.spacing) {
						ForEach(Array(row.enumerated()), id: \.element.id) { index, key in
							keyButton(key, index: index, count: row.count)
						}
					}

					// The row whose tooltip shows draws over the row under it.
					.zIndex(row.contains { $0.id == keyTooltip } ? 1 : 0)
				}
			}
			.arxTooltipTiming(hovered: hoveredKey, tooltip: $keyTooltip)

			// What a WebKit page lacks while it shows one (DEV-877), or why a site such as Netflix
			// offers WebKit when its video starts in Chromium (DEV-1188).
			if menu.shows(.webKit), let webKit = menu.webKit {
				if webKit.isShown {
					keyNote(Text(localized: .appUI.siteMenu.webKitNote))
				} else if webKit.playsVideoOnlyInWebKit {
					keyNote(Text(localized: .appUI.siteMenu.webKitVideoOnly))
				}
			}
		}
	}

	private func keyButton(
		_ key: SiteMenu.Key,
		index: Int,
		count: Int
	) -> some View {
		let title = Self.title(key.id)
		let tooltip: String = switch key.isOn {
		case true?: String.localized(.appUI.siteMenu.toggleOn(title))
		case false?: String.localized(.appUI.siteMenu.toggleOff(title))
		case nil: title
		}
		return Button {
			press(key)
		} label: {
			keyIcon(key)
				.frame(height: 20)
		}
		.buttonStyle(.arxRaised(.key, isSelected: key.isOn == true))
		.arxRaisedControlHeight(Grid.keyHeight)
		.frame(width: Grid.keyWidth)
		.disabled(!key.isEnabled)
		.focusEffectDisabled()
		.accessibilityLabel(Text(verbatim: title))
		.accessibilityValue(Text(verbatim: key.isOn.map {
			$0 ? String.localized(.appUI.command.settingOn) : String.localized(.appUI.command.settingOff)
		} ?? ""))
		.accessibilityAddTraits(key.isOn == nil ? [] : .isToggle)

		// A dimmed key still names itself on hover, so the reason it's there reads.
		.onHover { isHovering in
			if isHovering {
				hoveredKey = key.id
			} else if hoveredKey == key.id {
				hoveredKey = nil
			}
		}
		.overlay(alignment: ArxTooltip.alignment(index: index, count: count)) {
			if keyTooltip == key.id {
				ArxTooltip(tooltip)
					.offset(y: ArxTooltip.offset)
					.transition(.opacity)
			}
		}
	}

	@ViewBuilder
	private func keyIcon(_ key: SiteMenu.Key) -> some View {
		let size: CGFloat = 15
		switch key.id {
		case .capturePage:
			FigmaSymbol(.textViewfinder, pointSize: size)

		case .hideElement:
			// Hide Element's own mark, as its mode's toast shows it (DEV-1298).
			FigmaSymbol(.scope, pointSize: size)

		default:
			// Regular, as the Figma drawings beside them.
			Image(systemName: Self.symbol(key))
				.font(.system(size: size, weight: .regular))
				.accessibilityHidden(true)
		}
	}

	private func keyNote(_ text: Text) -> some View {
		text
			.font(.system(size: 11))
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
	}

	/// Actions close the menu; switches keep it open, so the key shows its new state.
	private func press(_ key: SiteMenu.Key) {
		switch key.id {
		case .share: leave(.share)
		case .captureRegion: leave(.captureRegion)
		case .capturePage: leave(.captureViewport)
		case .hideElement: leave(.hideElement)
		case .pagePictureInPicture: leave(.pagePictureInPicture)
		case .readingMode: leave(.readingMode)
		case .webKit: send(.setWebKit(key.isOn != true))
		case .darkPage: send(.setDarkPage(key.isOn != true))
		}
	}

	/// A key's name: its tooltip and what VoiceOver reads.
	internal static func title(_ key: SiteMenu.Key.ID) -> String {
		switch key {
		case .share: String.localized(.appUI.siteMenu.share)
		case .captureRegion: String.localized(.appUI.siteMenu.captureRegion)
		case .capturePage: String.localized(.appUI.siteMenu.capturePage)
		case .hideElement: String.localized(.appUI.siteMenu.hideElement)
		case .pagePictureInPicture: String.localized(.appUI.pagePicture.siteMenu)
		case .readingMode: String.localized(.appUI.reader.command)
		case .webKit: String.localized(.appUI.siteMenu.webKit)
		case .darkPage: String.localized(.appUI.darkPages.siteRow)
		}
	}

	internal static func symbol(_ key: SiteMenu.Key) -> String {
		switch key.id {
		case .share: "square.and.arrow.up"
		case .captureRegion: BrowserCommand.captureRegion.symbol
		case .capturePage: BrowserCommand.captureViewport.symbol
		case .hideElement: BrowserCommand.hideElement.symbol
		case .pagePictureInPicture: BrowserCommand.pagePictureInPicture.symbol
		case .readingMode: BrowserCommand.readingMode.symbol
		case .webKit: "safari"
		case .darkPage: key.isOn == true ? "moon.fill" : "moon"
		}
	}

	// MARK: - Extensions

	private func extensionsSection(_ extensions: [SiteMenu.Extension]) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 6) {
				sectionTitle(String.localized(.appUI.siteMenu.extensions))
				Spacer(minLength: 0)
				if menu.canOpenSettings, menu.shows(.manageExtensions) {
					Button(String.localized(.appUI.siteMenu.manage)) { leave(.manageExtensions) }
						.buttonStyle(.plain)
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(.secondary)
						.opacity(isHoveringExtensions ? 1 : 0)
						.accessibilityHidden(!isHoveringExtensions)
				}
				if menu.canOpenSettings, menu.shows(.addExtension) {
					Button { leave(.addExtension) } label: {
						Image(systemName: "plus")
							.font(.system(size: 11, weight: .semibold))
							.frame(width: 20, height: 20)
							.contentShape(.rect)
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
					.help(String.localized(.appUI.siteMenu.addExtension))
					.accessibilityLabel(String.localized(.appUI.siteMenu.addExtension))
				}
			}

			if extensions.isEmpty {
				Text(localized: menu.isLoading
				? .appUI.siteMenu.loading
				: menu.extensionsArePrivate ? .appUI.siteMenu.noPrivateExtensions : .appUI.siteMenu.noExtensions)
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
			} else {
				LazyVGrid(
					columns: Array(repeating: GridItem(.fixed(Grid.column), spacing: Grid.spacing), count: Grid.columns),
					alignment: .leading,
					spacing: Grid.spacing
				) {
					ForEach(extensions) { item in
						SiteMenuExtensionButton(item: item) { point in
							leave(.runExtension(item.id, screenPoint: point))
						}
						.help(item.name)
						.accessibilityLabel(item.name)
						.contextMenu { extensionMenu(item) }
					}
				}
			}

			// DEV-956: why a private window lacks some of the profile's extensions.
			if !menu.unavailableInPrivate.isEmpty {
				Text(String.localized(.appUI.siteMenu.unavailableInPrivate(
					ListFormatter.localizedString(byJoining: menu.unavailableInPrivate)
				)))
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			}
		}
		.contentShape(.rect)
		.onHover { isHoveringExtensions = $0 }
	}

	@ViewBuilder
	private func extensionMenu(_ item: SiteMenu.Extension) -> some View {
		if menu.canOpenSettings {
			if item.canOpenOptions {
				Button(String.localized(.appUI.extensions.options)) { leave(.openExtensionOptions(item.id)) }
			}

			// DEV-891: stop a misbehaving extension without going to Settings.
			if item.canTurnOff {
				Button(String.localized(.appUI.siteMenu.turnOffExtension)) { send(.turnOffExtension(item.id)) }
			}

			// DEV-889: whether it runs in private windows opened from this profile.
			if item.canAllowInPrivate {
				Toggle(
					String.localized(.appUI.siteMenu.allowExtensionInPrivate),
					isOn: Binding(
						get: { item.allowedInPrivate },
						set: { send(.setExtensionAllowedInPrivate(item.id, $0)) }
					)
				)
			}

			// DEV-1210: an update the automatic check left for the person's review.
			if item.needsUpdateReview {
				Button(String.localized(.appUI.siteMenu.reviewExtensionUpdate)) { leave(.reviewExtensionUpdate(item.id)) }
			}
			Button(String.localized(.appUI.siteMenu.manageExtensions)) { leave(.showExtension(item.id)) }
			if item.canRemove {
				Divider()
				Button(String.localized(.appUI.siteMenu.removeExtension), role: .destructive) {
					send(.requestExtensionRemoval(item.id))
				}
			}
		}
	}

	/// Remove…'s question, under the tiles (DEV-891).
	private func removalSection(_ item: SiteMenu.Extension) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(String.localized(.appUI.siteMenu.removeExtensionTitle(item.name)))
				.font(.system(size: 12, weight: .semibold))
			Text(localized: .appUI.siteMenu.removeExtensionMessage)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				Spacer()
				Button(String.localized(.appUI.siteMenu.cancel)) { send(.cancelExtensionRemoval) }
					.keyboardShortcut(.cancelAction)
				Button(String.localized(.appUI.siteMenu.remove), role: .destructive) { send(.confirmExtensionRemoval) }
					.keyboardShortcut(.defaultAction)
			}
			.controlSize(.small)
		}
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8, style: .continuous))
	}

	// MARK: - Site settings

	/// Whether the Site Settings list shows, which holds the Unread badges row too.
	private var showsPermissions: Bool {
		menu.shows(.permissions) && menu.permissions != nil
	}

	private func permissionsSection(_ permissions: [SiteMenu.Permission]) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			sectionTitle(String.localized(.appUI.siteMenu.siteSettings))
				.padding(.bottom, 4)

			if permissions.isEmpty, menu.isLoading {
				Text(localized: .appUI.siteMenu.loading)
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
			}

			if menu.shows(.contentBlocking), let blocksContent = menu.blocksContent {
				HStack(spacing: 6) {
					rowLabel(String.localized(.appUI.siteMenu.contentBlocking), symbol: "shield.lefthalf.filled")
						.frame(maxWidth: .infinity, alignment: .leading)
					if !blocksContent {
						Text(localized: .appUI.siteMenu.contentBlockingOff)
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
					}
					Toggle(
						String.localized(.appUI.siteMenu.contentBlocking),
						isOn: Binding(get: { blocksContent }, set: { send(.setContentBlocking($0)) })
					)
					.toggleStyle(.switch)
					.controlSize(.mini)
					.labelsHidden()
					.disabled(menu.isApplying || menu.contentBlockingIsManaged)
					.help(menu.contentBlockingIsManaged ? String.localized(.appUI.siteSettings.managed) : "")
				}
				.frame(minHeight: 24)
			}

			ForEach(permissions) { row in
				HStack(spacing: 6) {
					rowLabel(Self.name(row.permission), symbol: Self.symbol(row.permission), lineLimit: 2)
						.frame(maxWidth: .infinity, alignment: .leading)
					choicePicker(
						Self.name(row.permission),
						choice: row.choice,
						name: Self.name,
						selection: Binding(get: { row.setting }, set: { send(.setPermission(row.permission, $0)) })
					)
					.disabled(row.isManaged || menu.isApplying)
					.help(row.isManaged ? String.localized(.appUI.siteSettings.managed) : "")
				}
				.frame(minHeight: 24)
			}

			// The same row as the permissions' (DEV-1333): one list, one spacing, one pop-up width.
			if menu.shows(.unreadBadges), let unreadBadges = menu.unreadBadges {
				unreadBadgesRow(unreadBadges)
			}

			if menu.shows(.zoom), let zoom = menu.zoom {
				HStack(spacing: 8) {
					rowLabel(String.localized(.appUI.siteMenu.zoom), symbol: "plus.magnifyingglass")
					Spacer(minLength: 8)
					Text(zoom, format: .percent.precision(.fractionLength(0)))
						.font(.system(size: 12))
						.foregroundStyle(.secondary)
					Button(String.localized(.appUI.siteMenu.resetZoom)) { send(.resetZoom) }
						.controlSize(.small)
						.disabled(menu.isApplying)
				}
				.frame(minHeight: 24)
			}
		}
	}

	/// Translate from the page's language, and Never and Always for it (DEV-904).
	private func translationSection(_ translation: SiteMenu.Translation) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 6) {
				rowLabel(
					translation.isTranslated
					? String.localized(.appUI.translation.translatedFrom(translation.languageName))
					: String.localized(.appUI.siteMenu.translate(translation.languageName)),
					symbol: "translate"
				)
				.frame(maxWidth: .infinity, alignment: .leading)
				Toggle(
					String.localized(.appUI.translation.translatePage),
					isOn: Binding(get: { translation.isTranslated }, set: { send(.translate($0)) })
				)
				.toggleStyle(.switch)
				.controlSize(.mini)
				.labelsHidden()
			}
			.frame(minHeight: 24)
			Toggle(
				String.localized(.appUI.translation.neverSite),
				isOn: Binding(get: { translation.neverTranslatesSite }, set: { send(.setNeverTranslate($0)) })
			)
			.toggleStyle(.checkbox)
			.font(.system(size: 11))
			if translation.isTranslated {
				Toggle(
					String.localized(.appUI.translation.alwaysLanguage(translation.languageName)),
					isOn: Binding(get: { translation.alwaysTranslatesLanguage }, set: { send(.setAlwaysTranslate($0)) })
				)
				.toggleStyle(.checkbox)
				.font(.system(size: 11))
			}
		}
	}

	/// The devices the site may use, each with Forget (DEV-905).
	private func devicesSection(_ devices: [SiteMenu.Device]) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			sectionTitle(String.localized(.appUI.siteMenu.devices))
				.padding(.bottom, 4)
			ForEach(devices) { device in
				HStack(spacing: 6) {
					rowLabel(device.name, symbol: device.symbol)
						.frame(maxWidth: .infinity, alignment: .leading)
					Button(String.localized(.appUI.siteSettings.forgetDevice)) { send(.forgetDevice(device.id)) }
						.controlSize(.small)
						.disabled(menu.isApplying)
						.accessibilityLabel(String.localized(.appUI.siteMenu.forgetDevice(device.name)))
				}
				.frame(minHeight: 24)
			}
		}
	}

	/// The elements hidden on the site, each with Show (DEV-1019). Hide Element… is a key since
	/// DEV-1333.
	private func hiddenElementsSection(_ elements: [SiteMenu.HiddenElement]) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			if !elements.isEmpty {
				sectionTitle(String.localized(.appUI.siteMenu.hiddenElements))
					.padding(.bottom, 4)
			}

			// A site with many hidden elements scrolls them; Hide Element… stays below.
			ScrollView {
				VStack(alignment: .leading, spacing: 4) {
					ForEach(elements) { element in
						HStack(spacing: 6) {
							HStack(spacing: 6) {
								Image(systemName: "eye.slash")
									.font(.system(size: 12))
									.foregroundStyle(.secondary)
									.frame(width: 18)
									.accessibilityHidden(true)
								Text(element.selector)
									.font(.system(size: 12, design: .monospaced))
									.lineLimit(1)
									.truncationMode(.middle)
							}
							.frame(maxWidth: .infinity, alignment: .leading)
							.help(element.id)
							Button(String.localized(.appUI.siteMenu.showHiddenElement)) { send(.showHiddenElement(element.id)) }
								.controlSize(.small)
								.disabled(menu.isApplying)
								.accessibilityLabel(String.localized(.appUI.siteMenu.showHiddenElementNamed(element.selector)))
						}
						.frame(minHeight: 24)
					}
				}
			}
			.scrollBounceBehavior(.basedOnSize)
			.frame(maxHeight: 24 * 8 + 4 * 7)
			.fixedSize(horizontal: false, vertical: true)
		}
	}

	/// The site's unread badges (DEV-1258): its tabs and Favorites show them, hide them, or follow
	/// the profile and the browser default.
	private func unreadBadgesRow(_ unreadBadges: SiteMenu.UnreadBadges) -> some View {
		HStack(spacing: 6) {
			rowLabel(String.localized(.appUI.unreadBadges.siteRow), symbol: "app.badge", lineLimit: 2)
				.frame(maxWidth: .infinity, alignment: .leading)
			choicePicker(
				String.localized(.appUI.unreadBadges.siteRow),
				choice: unreadBadges.choice,
				name: \.title,
				selection: Binding(get: { unreadBadges.site }, set: { send(.setUnreadBadges($0)) })
			)
			.disabled(menu.isApplying)
		}
		.frame(minHeight: 24)
	}

	/// A row's symbol in a fixed column, so the titles line up.
	private func rowLabel(
		_ title: String,
		symbol: String,
		lineLimit: Int = 1
	) -> some View {
		HStack(spacing: 6) {
			Image(systemName: symbol)
				.frame(width: 18)
				.accessibilityHidden(true)
			Text(title)
				.lineLimit(lineLimit)
				.fixedSize(horizontal: false, vertical: true)
		}
		.font(.system(size: 12))
		.accessibilityElement(children: .combine)
	}

	/// A row's pop-up (DEV-1333): closed, the value the site gets, such as "Ask"; open, "Default
	/// (Ask)" and then each option, with the stored one checked. Every pop-up in the menu shares
	/// the width of the widest option any of them can show, so their edges line up and none
	/// changes width with its value.
	private func choicePicker<Value: Hashable & Sendable>(
		_ title: String,
		choice: SiteMenu.Choice<Value>,
		name: @escaping (Value) -> String,
		selection: Binding<Value?>
	) -> some View {
		Menu {
			Picker(title, selection: selection) {
				Text(String.localized(.appUI.siteMenu.defaultSetting(name(choice.inherited))))
					.tag(Value?.none)
				ForEach(choice.options, id: \.self) { option in
					Text(name(option)).tag(Optional(option))
				}
			}
			.pickerStyle(.inline)
			.labelsHidden()
		} label: {
			HStack(spacing: 4) {
				Text(name(choice.effective))
					.lineLimit(1)
					.frame(maxWidth: .infinity, alignment: .leading)
				Image(systemName: "chevron.up.chevron.down")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(.secondary)
			}
			.font(.system(size: 12))
			.padding(.leading, 8)
			.padding(.trailing, 6)
			.frame(height: 22)
			.background(.quaternary, in: ArxControlShape())
			.contentShape(ArxControlShape())
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.frame(width: max(Self.minimumPickerWidth, widestPicker))
		.background {
			// Measures the widest option this pop-up can show; the visible ones take the widest.
			ZStack {
				ForEach(choice.options, id: \.self) { option in
					Self.pickerLabelProbe(name(option))
				}
			}
			.fixedSize()
			.hidden()
			.onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
				widestPicker = max(widestPicker, width)
			}
		}
		.accessibilityLabel(Text(verbatim: title))
		.accessibilityValue(Text(verbatim: Self.pickerValue(choice, name: name)))
	}

	/// What VoiceOver reads for a pop-up: "Default (Ask)" while the site follows the default.
	private static func pickerValue<Value: Hashable & Sendable>(
		_ choice: SiteMenu.Choice<Value>,
		name: (Value) -> String
	) -> String {
		guard choice.isDefault else { return name(choice.effective) }
		return String.localized(.appUI.siteMenu.defaultSetting(name(choice.effective)))
	}

	/// A closed pop-up's label with `text` at its own width, to measure.
	private static func pickerLabelProbe(_ text: String) -> some View {
		HStack(spacing: 4) {
			Text(text)
			Image(systemName: "chevron.up.chevron.down")
				.font(.system(size: 9, weight: .semibold))
		}
		.font(.system(size: 12))
		.padding(.leading, 8)
		.padding(.trailing, 6)
	}

	// MARK: - Clearing

	@ViewBuilder
	private func clearingSection(_ clearing: SiteMenu.Clearing) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			switch clearing {
			case .scoping:
				ProgressView()
					.controlSize(.small)

			case let .confirming(kind, domain):
				Text(Self.clearTitle(kind, domain: domain))
					.font(.system(size: 12, weight: .semibold))
				Text(Self.clearMessage(kind, domain: domain, profile: menu.profileName))
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				HStack {
					Spacer()
					Button(String.localized(.appUI.siteMenu.cancel)) { send(.cancelClear) }
						.keyboardShortcut(.cancelAction)
					Button(String.localized(.appUI.siteMenu.clear), role: .destructive) { send(.confirmClear) }
						.keyboardShortcut(.defaultAction)
				}
				.controlSize(.small)

			case .clearing:
				HStack(spacing: 8) {
					ProgressView()
						.controlSize(.small)
					Text(localized: .appUI.siteMenu.clearing)
						.font(.system(size: 12))
						.foregroundStyle(.secondary)
				}

			case let .cleared(kind, domain, isComplete):
				noticeRow(
					isComplete
					? (kind == .cookies
					? String.localized(.appUI.siteMenu.cookiesCleared(domain))
					: String.localized(.appUI.siteMenu.cacheCleared(domain)))
					: String.localized(.appUI.siteMenu.partiallyCleared(domain))
				)

			case .failed:
				noticeRow(String.localized(.appUI.siteMenu.clearFailed))
			}
		}
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8, style: .continuous))
	}

	private func noticeRow(_ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Text(text)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 0)
			Button {
				send(.dismissNotice)
			} label: {
				Image(systemName: "xmark")
					.font(.system(size: 9, weight: .semibold))
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			.accessibilityLabel(String.localized(.appUI.siteMenu.cancel))
		}
	}

	// MARK: - Connection

	private var connectionRow: some View {
		HStack(spacing: 6) {
			Image(systemName: connectionSymbol)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(menu.connection == .notSecure ? Color.orange : Color.secondary)
			Text(connectionTitle)
				.font(.system(size: 12, weight: .medium))
			Text(menu.host)
				.font(.system(size: 12))
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer(minLength: 4)
			if showsClearSiteData || showsSettingsItems {
				Menu {
					if showsClearSiteData {
						Button(String.localized(.appUI.siteMenu.clearCache)) { send(.requestClear(.cache)) }
						Button(String.localized(.appUI.siteMenu.clearCookies)) { send(.requestClear(.cookies)) }
					}
					if showsSettingsItems {
						if showsClearSiteData { Divider() }
						if menu.shows(.manageExtensions) {
							Button(String.localized(.appUI.siteMenu.manageExtensions)) { leave(.manageExtensions) }
						}
						if menu.shows(.addExtension) {
							Button(String.localized(.appUI.siteMenu.addExtension)) { leave(.addExtension) }
						}
						if menu.shows(.allSiteSettings) {
							Divider()
							Button(String.localized(.appUI.siteMenu.allSiteSettings)) { leave(.allSiteSettings) }
						}
					}
				} label: {
					Image(systemName: "ellipsis")
						.font(.system(size: 12, weight: .semibold))
						.frame(width: 22, height: 18)
				}
				.menuStyle(.button)
				.buttonStyle(.plain)
				.menuIndicator(.hidden)
				.fixedSize()
				.disabled(isClearing)
				.help(String.localized(.appUI.siteMenu.more))
				.accessibilityLabel(String.localized(.appUI.siteMenu.more))
			}
		}
	}

	private var showsClearSiteData: Bool {
		menu.canClearSiteData && menu.shows(.clearSiteData)
	}

	/// The "…" menu's Settings items, for a profile Settings lists.
	private var showsSettingsItems: Bool {
		menu.canOpenSettings
		&& [.manageExtensions, .addExtension, .allSiteSettings].contains(where: menu.shows)
	}

	private var isClearing: Bool {
		switch menu.clearing {
		case .scoping, .confirming, .clearing: true
		default: false
		}
	}

	private var connectionSymbol: String {
		switch menu.connection {
		case .secure: "lock.fill"
		case .notSecure: "exclamationmark.triangle.fill"
		case .local: "doc"
		}
	}

	private var connectionTitle: String {
		switch menu.connection {
		case .secure: String.localized(.appUI.siteMenu.secure)
		case .notSecure: String.localized(.appUI.siteMenu.notSecure)
		case .local: String.localized(.appUI.siteMenu.local)
		}
	}

	// MARK: - Helpers

	private func sectionTitle(_ title: String) -> some View {
		Text(title)
			.font(.system(size: 11, weight: .semibold))
			.foregroundStyle(.secondary)
			.accessibilityAddTraits(.isHeader)
	}

	private func leave(_ action: SiteMenuAction) {
		dismiss()
		send(action)
	}

	public static func name(_ permission: SitePermission) -> String {
		switch permission {
		case .camera: String.localized(.appUI.siteSettings.permission.camera)
		case .microphone: String.localized(.appUI.siteSettings.permission.microphone)
		case .location: String.localized(.appUI.siteSettings.permission.location)
		case .notifications: String.localized(.appUI.siteSettings.permission.notifications)
		case .popups: String.localized(.appUI.siteSettings.permission.popups)
		case .clipboard: String.localized(.appUI.siteSettings.permission.clipboard)
		}
	}

	public static func name(_ setting: SitePermissionSetting) -> String {
		switch setting {
		case .allow: String.localized(.appUI.siteSettings.setting.allow)
		case .block: String.localized(.appUI.siteSettings.setting.block)
		case .ask: String.localized(.appUI.siteSettings.setting.ask)
		}
	}

	internal nonisolated static func symbol(_ permission: SitePermission) -> String {
		switch permission {
		case .camera: "video"
		case .microphone: "mic"
		case .location: "location"
		case .notifications: "bell"
		case .popups: "macwindow.on.rectangle"
		case .clipboard: "doc.on.clipboard"
		}
	}

	internal static func clearTitle(
		_ kind: SiteMenu.ClearKind,
		domain: String
	) -> String {
		switch kind {
		case .cache: String.localized(.appUI.siteMenu.clearCacheTitle(domain))
		case .cookies: String.localized(.appUI.siteMenu.clearCookiesTitle(domain))
		}
	}

	internal static func clearMessage(
		_ kind: SiteMenu.ClearKind,
		domain: String,
		profile: String?
	) -> String {
		let profile = profile ?? ""
		return switch kind {
		case .cache: String.localized(.appUI.siteMenu.clearCacheMessage(domain, profile))
		case .cookies: String.localized(.appUI.siteMenu.clearCookiesMessage(domain, profile))
		}
	}
}

/// An extension's tile. Its action reports the tile's bottom centre in AppKit screen
/// coordinates, read while the panel still shows it, where the extension's popup opens (DEV-828).
private struct SiteMenuExtensionButton: View {
	private let item: SiteMenu.Extension
	private let action: (CGPoint) -> Void

	@SwiftUI.State
	private var anchor: SiteMenuScreenAnchor = .init()

	fileprivate init(
		item: SiteMenu.Extension,
		action: @escaping (CGPoint) -> Void
	) {
		self.item = item
		self.action = action
	}

	fileprivate var body: some View {
		Button { action(anchor.point) } label: {
			ExtensionIconTile(name: item.name, icon: item.icon)
				.background(SiteMenuScreenAnchorView(anchor: anchor))

				// DEV-1210: an update waits for review; the tile's menu opens it.
				.overlay(alignment: .topTrailing) {
					if item.needsUpdateReview {
						Circle()
							.fill(.orange)
							.frame(width: 8, height: 8)
							.offset(x: 2, y: -2)
							.accessibilityHidden(true)
					}
				}
		}
		.buttonStyle(.plain)
		.accessibilityValue(item.needsUpdateReview ? String.localized(.appUI.extensions.updateNeedsReview) : "")
	}
}

/// The AppKit view under a tile, held weakly, to tell where the tile is on screen.
@MainActor
private final class SiteMenuScreenAnchor {
	internal weak var view: NSView?

	/// The view's bottom centre on screen; the pointer when the view isn't in a window.
	internal var point: CGPoint {
		guard let view, let window = view.window else { return NSEvent.mouseLocation }

		let bounds = view.bounds
		let bottom = NSPoint(x: bounds.midX, y: view.isFlipped ? bounds.maxY : bounds.minY)
		return window.convertPoint(toScreen: view.convert(bottom, to: nil))
	}
}

private struct SiteMenuScreenAnchorView: NSViewRepresentable {
	private let anchor: SiteMenuScreenAnchor

	fileprivate init(anchor: SiteMenuScreenAnchor) {
		self.anchor = anchor
	}

	fileprivate func makeNSView(context: Context) -> NSView {
		let view = NSView()
		anchor.view = view
		return view
	}

	fileprivate func updateNSView(
		_ view: NSView,
		context: Context
	) {
		anchor.view = view
	}
}

#Preview("Site menu") {
	SiteMenuPanel(
		menu: .init(
			host: "github.com",
			connection: .secure,
			profileName: "Personal",
			extensions: [.init(id: "a", name: "1Password"), .init(id: "b", name: "uBlock Origin Lite")],
			permissions: SitePermission.allCases.map {
				.init(permission: $0, setting: $0 == .camera ? .allow : nil, defaultSetting: $0 == .popups ? .block : .ask)
			},
			zoom: 1.25,
			canClearSiteData: true,
			canOpenSettings: true
		),
		send: { _ in },
		dismiss: {}
	)
}
