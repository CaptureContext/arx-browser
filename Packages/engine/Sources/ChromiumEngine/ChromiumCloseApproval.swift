import ChromiumBridge
import Foundation

/// Opaque, one-use native authority. Only its originating runtime can consume it.
public struct ChromiumCloseApproval: Equatable, Sendable {
	internal let owner: UUID
	internal let page: UInt64
	internal let request: UInt64
	internal let token: UInt64

	internal init(
		owner: UUID,
		page: UInt64,
		request: UInt64,
		token: UInt64
	) {
		self.owner = owner
		self.page = page
		self.request = request
		self.token = token
	}
}

public enum ChromiumCloseFailure: Error, Equatable, Sendable {
	case staleDocument
	case busy
	case unavailable
	case timedOut
}

@MainActor
internal final class ChromiumCloseRequests {
	private let api: ArxEngineAPI
	private let owner: UUID = .init()
	private let timeout: Duration
	private var nextRequest: UInt64 = 1
	private var pending: [UInt64: Pending] = [:]
	private var approved: [UInt64: ChromiumCloseApproval] = [:]

	internal init(
		api: ArxEngineAPI,
		timeout: Duration = .seconds(30)
	) {
		self.api = api
		self.timeout = timeout
	}

	internal func request(
		page: UInt64,
		generation: UInt64
	) async throws -> ChromiumCloseApproval? {
		try Task.checkCancellation()
		guard generation != 0, nextRequest != 0
		else { throw ChromiumCloseFailure.staleDocument }

		let request = nextRequest
		nextRequest &+= 1
		let approval: ChromiumCloseApproval? = try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				guard !Task.isCancelled else {
					continuation.resume(throwing: CancellationError())
					return
				}

				let timeout = Task { [weak self, timeout] in
					do {
						try await Task.sleep(for: timeout)
					} catch {
						return
					}

					self?.cancel(request, error: ChromiumCloseFailure.timedOut)
				}

				pending[request] = .init(
					page: page,
					continuation: continuation,
					timeout: timeout
				)
				api.request_authorized_close(page, request, generation)
			}
		} onCancel: { [weak self] in
			Task { @MainActor [weak self] in
				self?.cancel(request, error: CancellationError())
			}
		}

		if Task.isCancelled {
			cancel(request, error: CancellationError())
			throw CancellationError()
		}

		return approval
	}

	internal func complete(
		request: UInt64,
		page: UInt64,
		status: ArxCloseStatus,
		token: UInt64
	) {
		guard let pending = pending.removeValue(forKey: request)
		else { return }

		pending.timeout.cancel()

		do {
			guard page == pending.page
			else { throw ChromiumCloseFailure.staleDocument }

			switch status {
			case ARX_CLOSE_SUCCESS:
				guard token != 0
				else { throw ChromiumCloseFailure.staleDocument }

				let approval = ChromiumCloseApproval(
					owner: owner,
					page: page,
					request: request,
					token: token
				)
				approved[request] = approval
				pending.continuation.resume(returning: approval)

			case ARX_CLOSE_REFUSED: pending.continuation.resume(returning: nil)

			case ARX_CLOSE_BUSY: throw ChromiumCloseFailure.busy

			case ARX_CLOSE_CANCELLED: throw CancellationError()

			case ARX_CLOSE_UNAVAILABLE: throw ChromiumCloseFailure.unavailable

			default: throw ChromiumCloseFailure.staleDocument
			}
		} catch {
			api.cancel_authorized_close(pending.page, request)
			pending.continuation.resume(throwing: error)
		}
	}

	internal func consume(
		_ approval: ChromiumCloseApproval,
		page: UInt64
	) throws {
		guard
			approval.owner == owner,
			approval.page == page,
			approved[approval.request] == approval
		else { throw ChromiumCloseFailure.staleDocument }

		approved[approval.request] = nil
		guard
			api.consume_authorized_close(page, approval.request, approval.token) == ARX_CLOSE_SUCCESS
		else {
			api.cancel_authorized_close(page, approval.request)
			throw ChromiumCloseFailure.staleDocument
		}
	}

	internal func cancel(_ approval: ChromiumCloseApproval) {
		guard
			approval.owner == owner,
			approved[approval.request] == approval
		else { return }

		cancel(approval.request, error: CancellationError())
	}

	internal func remove(page: UInt64) {
		let requests = pending.filter { $0.value.page == page }.keys
		for request in requests {
			cancel(request, error: ChromiumCloseFailure.staleDocument)
		}

		for approval in approved.values where approval.page == page { cancel(approval) }
	}

	internal func finish() {
		for value in pending.values {
			value.timeout.cancel()
			value.continuation.resume(throwing: ChromiumCloseFailure.unavailable)
		}

		pending.removeAll()
		approved.removeAll()
	}

	private func cancel(
		_ request: UInt64,
		error: any Error
	) {
		if let value = pending.removeValue(forKey: request) {
			value.timeout.cancel()
			api.cancel_authorized_close(value.page, request)
			value.continuation.resume(throwing: error)
		}

		if let value = approved.removeValue(forKey: request) {
			api.cancel_authorized_close(value.page, request)
		}
	}

	private struct Pending {
		internal let page: UInt64
		internal let continuation: CheckedContinuation<ChromiumCloseApproval?, any Error>
		internal let timeout: Task<Void, Never>

		internal init(
			page: UInt64,
			continuation: CheckedContinuation<ChromiumCloseApproval?, any Error>,
			timeout: Task<Void, Never>
		) {
			self.page = page
			self.continuation = continuation
			self.timeout = timeout
		}
	}
}
