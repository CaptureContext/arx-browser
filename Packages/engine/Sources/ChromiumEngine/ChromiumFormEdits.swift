import Foundation

/// `void (*reply)(void* context, uint64_t request, uint64_t page, int32_t result)`: called once, on
/// the main thread, after `ArxEngineCheckPageFormEdits` returned true.
internal typealias ChromiumFormEditsReply = @convention(c) (
	UnsafeMutableRawPointer?,
	UInt64,
	UInt64,
	Int32
) -> Void

/// `bool ArxEngineCheckPageFormEdits(uint64_t page, uint64_t request, reply, void* context)`
/// (DEV-1084): main thread, once the engine runs. Checks every frame of the page's current
/// document, cross-origin ones too, for form input a person typed and hasn't sent, and replies
/// within about two seconds with only the answer. False, with no reply, for an unknown page.
/// Outside the ABI table, like the other optional exports.
internal typealias ChromiumFormEditsFunction = @convention(c) (
	UInt64,
	UInt64,
	ChromiumFormEditsReply?,
	UnsafeMutableRawPointer?
) -> Bool

internal let ChromiumFormEditsSymbol: String = "ArxEngineCheckPageFormEdits"

/// Whether a page holds form input a person typed and hasn't sent, in any of its frames
/// (DEV-1084).
public enum ChromiumFormEdits: Equatable, Sendable {
	/// Nothing typed, or nothing to lose: an unloaded, crashed or closing page, or one that isn't
	/// on the web.
	case clean

	/// A frame holds typed input: a changed or filled field, a changed choice, or an editable area
	/// with text.
	case typed

	/// A frame didn't answer in time, the page has more frames than the engine reads, or it
	/// navigated meanwhile.
	case unknown

	internal init(result: Int32) {
		switch result {
		case 0: self = .clean
		case 1: self = .typed
		default: self = .unknown
		}
	}
}

extension ChromiumRuntime {
	/// Whether this engine can check a page's frames for typed input (DEV-1084).
	public var supportsFormEdits: Bool {
		state == .running && optionalExports.formEdits != nil
	}

	/// Whether `page` holds form input a person typed and hasn't sent, in any frame. Nil when the
	/// engine can't tell: an engine without the check, one that isn't running, or a closed page.
	/// The answer comes within about two seconds; no value on the page is read out of it.
	public func formEdits(on page: ChromiumPage) async -> ChromiumFormEdits? {
		guard
			state == .running,
			let check = optionalExports.formEdits,
			pages[page.id] === page,
			!page.isClosed
		else { return nil }

		let revision = documentRevision(for: page)
		let edits: ChromiumFormEdits? = await withCheckedContinuation { continuation in
			let request: ChromiumFormEditsRequest = .init(continuation)
			let context: UnsafeMutableRawPointer = Unmanaged.passRetained(request).toOpaque()
			guard check(page.id, ChromiumFormEditsRequest.nextID(), chromiumFormEditsReply, context) else {
				Unmanaged<ChromiumFormEditsRequest>.fromOpaque(context).release()
				request.resume(nil)
				return
			}

			// The engine always replies; this only covers one that stops first.
			Task { @MainActor in
				try? await Task.sleep(for: .seconds(5))
				request.resume(.unknown)
			}
		}

		// A page that moved to another document before the reply arrived wasn't the one checked.
		guard edits == .clean, documentRevision(for: page) != revision else { return edits }
		return .unknown
	}
}

/// One check, answered once: by the engine's reply, or by the fallback after five seconds.
@MainActor
private final class ChromiumFormEditsRequest {
	private static var lastID: UInt64 = 0
	private var continuation: CheckedContinuation<ChromiumFormEdits?, Never>?

	fileprivate init(_ continuation: CheckedContinuation<ChromiumFormEdits?, Never>) {
		self.continuation = continuation
	}

	fileprivate static func nextID() -> UInt64 {
		lastID &+= 1
		return lastID
	}

	fileprivate func resume(_ edits: ChromiumFormEdits?) {
		continuation?.resume(returning: edits)
		continuation = nil
	}
}

/// Takes back the request the call retained and answers it.
private let chromiumFormEditsReply: ChromiumFormEditsReply = { context, _, _, result in
	guard let context else { return }

	let request = Unmanaged<ChromiumFormEditsRequest>.fromOpaque(context).takeRetainedValue()
	MainActor.assumeIsolated {
		request.resume(.init(result: result))
	}
}
