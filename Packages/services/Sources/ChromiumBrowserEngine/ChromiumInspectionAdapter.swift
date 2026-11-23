import BrowserCore
import BrowserPageInspectionClient
import ChromiumEngine
import Foundation

internal enum ChromiumInspectionAdapter {
	@MainActor
	internal static func client(
		isAvailable: @escaping @MainActor @Sendable () -> Bool,
		sourceIsCurrent: @escaping @MainActor @Sendable (PageInspectionSource) -> Bool,
		inspect: @escaping @MainActor @Sendable (
			PageInspectionSource,
			String?,
			ChromiumInspectionLimits
		) async throws -> ChromiumInspectionSnapshot,
		documentIsCurrent: @escaping @MainActor @Sendable (
			ChromiumInspectionSnapshot,
			PageInspectionSource
		) -> Bool,
		revokeScope: @escaping @MainActor @Sendable (UUID) -> Void
	) -> BrowserPageInspectionClient {
		.init(
			isAvailable: isAvailable,
			inspectAuthorized: { request, source, authorize in
				try request.validate()
				try Task.checkCancellation()
				guard isAvailable() else { throw AutomationFailure.notReady }
				guard
					request.targetID == source.tabID.rawValue,
					source.documentRevision > 0,
					authorize(),
					sourceIsCurrent(source)
				else { throw AutomationFailure.staleTarget }

				let snapshot: ChromiumInspectionSnapshot
				do {
					snapshot = try await inspect(
						source,
						request.frameID,
						.init(
							maximumNodes: request.maximumNodes,
							maximumTextBytes: request.maximumTextBytes,
							maximumOutputBytes: 114_688,
							windowStart: request.windowStart,
							includesFormValues: request.includesFormValues,
							includesBounds: request.includesBounds
						)
					)
				} catch let error as ChromiumInspectionFailure {
					throw failure(error)
				}

				try Task.checkCancellation()
				guard isAvailable() else { throw AutomationFailure.notReady }
				guard
					authorize(),
					sourceIsCurrent(source),
					documentIsCurrent(snapshot, source)
				else { throw AutomationFailure.staleTarget }

				let result = snapshot.value
				try result.validate(for: request)
				return result
			},
			documentIsCurrent: { result in
				isAvailable()
				&& sourceIsCurrent(result.source)
				&& documentIsCurrent(.init(result.snapshot), result.source)
			},
			revokeScope: revokeScope
		)
	}

	private static func failure(_ error: ChromiumInspectionFailure) -> AutomationFailure {
		switch error {
		case .unavailable: .unsupported
		case .notReady: .notReady
		case .unsupportedDocument: .unsupported
		case .staleReference: .staleTarget
		case .limitExceeded: .limitExceeded
		case .timedOut: .timedOut
		case .busy: .busy
		case .invalidResponse: .engineFailed
		}
	}
}

extension ChromiumInspectionSnapshot {
	fileprivate var value: PageInspectionSnapshot {
		.init(
			snapshotID: snapshotID,
			documentID: documentID,
			frameID: frameID,
			domVersion: domVersion,
			nodes: nodes.map {
				.init(
					index: $0.index,
					parent: $0.parent,
					role: $0.role,
					name: $0.name,
					text: $0.text,
					reference: $0.reference,
					value: $0.value,
					checked: $0.checked,
					bounds: $0.bounds.map {
						.init(x: Double($0.x), y: Double($0.y), width: Double($0.width), height: Double($0.height))
					},
					frame: $0.frame
				)
			},
			omissions: omissions.compactMap { PageInspectionOmission(rawValue: $0.rawValue) },
			windowStart: windowStart,
			totalNodes: totalNodes
		)
	}

	internal init(_ snapshot: PageInspectionSnapshot) {
		self.init(
			snapshotID: snapshot.snapshotID,
			documentID: snapshot.documentID,
			frameID: snapshot.frameID,
			domVersion: snapshot.domVersion,
			nodes: snapshot.nodes.map {
				.init(
					index: $0.index,
					parent: $0.parent,
					role: $0.role,
					name: $0.name,
					text: $0.text,
					reference: $0.reference,
					value: $0.value,
					checked: $0.checked,
					bounds: $0.bounds.map {
						.init(x: Int($0.x), y: Int($0.y), width: Int($0.width), height: Int($0.height))
					},
					frame: $0.frame
				)
			},
			omissions: snapshot.omissions.compactMap {
				ChromiumInspectionOmission(rawValue: $0.rawValue)
			},
			windowStart: snapshot.windowStart,
			totalNodes: snapshot.totalNodes
		)
	}
}
