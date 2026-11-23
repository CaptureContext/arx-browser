import AppKit
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// A light haptic when Force Click hands a link to Peek or Little Arx.
///
/// The press has already clicked the trackpad; this tap tells the user that Arx took the
/// link instead of Look Up. Peek itself grows from the pressed point and only fades with
/// Reduce Motion on. AppKit drops the haptic on a trackpad that can't play it.
public struct LinkActivationFeedback: Sendable {
	public var perform: @MainActor @Sendable () -> Void

	public init(perform: @escaping @MainActor @Sendable () -> Void) {
		self.perform = perform
	}
}

extension LinkActivationFeedback: DependencyKey {
	public static var liveValue: Self {
		.init {
			NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
		}
	}

	public static var testValue: Self {
		.init { reportIssue("LinkActivationFeedback.perform is unimplemented") }
	}
}

extension DependencyValues {
	public var linkActivationFeedback: LinkActivationFeedback {
		get { self[LinkActivationFeedback.self] }
		set { self[LinkActivationFeedback.self] = newValue }
	}
}

extension AppFeature.State {
	/// Takes a Force Click for Peek or Little Arx, with one haptic when Arx takes it and
	/// haptics are on in Settings.
	/// False leaves the press to Chromium, without feedback.
	@MainActor
	internal func takeLinkForceClick(
		_ click: BrowserLinkForceClick,
		pointer: CGPoint? = NSEvent.mouseLocation,
		engine: BrowserEngineClient,
		send: (AppFeature.Action) -> Void
	) -> Bool {
		guard let action = linkForceClickAction(for: click, pointer: pointer, engine: engine)
		else { return false }

		@Dependency(\.linkActivationFeedback)
		var feedback

		if settings.general.hapticsEnabled { feedback.perform() }
		send(action)
		return true
	}
}
