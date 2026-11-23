#if DEBUG
import BrowserAutomationClient
import BrowserCore
import Darwin
import Foundation
import _MCP

/// These checks precede every preference mutation and helper launch.
internal enum AutomationSmokeFixture {
	internal static let sentinel: String = "Arx MCP disposable fixture v1\n"

	internal static func validate(
		root: URL,
		profile: URL,
		baseURL: URL,
		preferences: AutomationPreferences
	) throws {
		guard !preferences.isEnabled, preferences.clients.isEmpty
		else { throw AutomationSmokeFailure.existingAuthorization }
		guard
			root.isFileURL,
			profile.isFileURL,
			root.lastPathComponent.hasPrefix("app-smoke-"),
			profile.standardizedFileURL == root.appendingPathComponent("profile").standardizedFileURL,
			validFile(root, kind: S_IFDIR, permissions: 0o700),
			validFile(profile, kind: S_IFDIR, permissions: 0o700),
			profile.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			(1...65535).contains(parts.port ?? 0),
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil,
			parts.path == "/index.html"
		else { throw AutomationSmokeFailure.invalidFixture }

		let marker = root.appendingPathComponent(".arx-mcp-smoke")
		guard
			validFile(marker, kind: S_IFREG, permissions: 0o600, size: sentinel.utf8.count),
			(try? Data(contentsOf: marker)) == Data(sentinel.utf8)
		else { throw AutomationSmokeFailure.invalidFixture }
	}

	private static func validFile(
		_ url: URL,
		kind: mode_t,
		permissions: mode_t,
		size: Int? = nil
	) -> Bool {
		var information = stat()
		guard
			lstat(url.path, &information) == 0,
			information.st_uid == getuid(),
			information.st_mode & S_IFMT == kind,
			information.st_mode & 0o777 == permissions
		else { return false }

		return size.map { information.st_size == $0 } ?? true
	}
}

/// Error payloads deliberately contain no credentials, configuration, URLs or remote text.
internal enum AutomationSmokeFailure: String, Error {
	case invalidFixture
	case existingAuthorization
	case missingSource
	case setupFailed
	case invalidResponse
	case inventoryMismatch
	case navigationMismatch
	case authorizationFailed
	case timedOut
	case helperFailed
	case cleanupFailed
	case atomicCloseUnavailable
	case captureMismatch
	case inspectionMismatch
	case clickMismatch
	case formMismatch
	case scrollMismatch
	case waitMismatch
	case hostMismatch
}

internal struct AutomationSmokeConfiguration {
	internal let clientID: UUID
	internal let environment: [String: String]

	internal init(
		json: String,
		helper: URL,
		socket: String,
		client: AutomationClient
	) throws {
		guard
			json.utf8.count <= 8192,
			let value = try? JSONDecoder().decode(Configuration.self, from: Data(json.utf8)),
			Set(value.mcpServers.keys) == ["arx"],
			let server = value.mcpServers["arx"],
			server.command == helper.path,
			Set(server.env.keys) == ["ARX_MCP_SOCKET", "ARX_MCP_CLIENT_ID", "ARX_MCP_CREDENTIAL"],
			server.env["ARX_MCP_SOCKET"] == socket,
			server.env["ARX_MCP_CLIENT_ID"] == client.id.uuidString,
			let credential = server.env["ARX_MCP_CREDENTIAL"],
			credential.utf8.count == 64,
			credential.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
			AutomationSecurity.matches(token: credential, digest: client.credentialDigest)
		else { throw AutomationSmokeFailure.invalidResponse }

		self.clientID = client.id
		self.environment = server.env
	}

	private struct Configuration: Decodable {
		fileprivate let mcpServers: [String: Server]

		fileprivate init(mcpServers: [String: Server]) {
			self.mcpServers = mcpServers
		}
	}

	private struct Server: Decodable {
		fileprivate let command: String
		fileprivate let env: [String: String]

		fileprivate init(
			command: String,
			env: [String: String]
		) {
			self.command = command
			self.env = env
		}
	}
}

internal enum AutomationSmokeResponse {
	internal static func decode(_ result: CallTool.Result) throws -> AutomationResult {
		guard
			result.content.count == 1,
			case let .text(text, _, _) = result.content[0],
			text.utf8.count <= 262_144,
			let structured = result.structuredContent,
			let textValue = try? JSONDecoder().decode(Value.self, from: Data(text.utf8)),
			textValue == structured,
			let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)),
			envelope.untrustedData
		else { throw AutomationSmokeFailure.invalidResponse }

		let payload = envelope.result
		switch payload.kind {
		case "inventory":
			guard
				result.isError == false,
				let items = payload.items,
				items.count <= 100,
				Set(items.map(\.id)).count == items.count,
				items.allSatisfy({ $0.urlSanitized && $0.revision.utf8.count == 64 }),
				payload.nextCursor.map({ $0.utf8.count <= 96 }) ?? true
			else { throw AutomationSmokeFailure.invalidResponse }

			return .inventory(.init(
				items: items,
				nextCursor: payload.nextCursor,
				presentations: payload.presentations ?? []
			))

		case "command":
			guard
				result.isError == false,
				let operationID = payload.operationID,
				let status = payload.status
			else { throw AutomationSmokeFailure.invalidResponse }

			return .command(.init(
				operationID: operationID,
				status: status,
				targetID: payload.targetID,
				presentation: payload.presentation
			))

		case "error":
			guard result.isError == true, let code = payload.code
			else { throw AutomationSmokeFailure.invalidResponse }

			return .failure(code)

		default:
			throw AutomationSmokeFailure.invalidResponse
		}
	}

	private struct Envelope: Decodable {
		fileprivate let untrustedData: Bool
		fileprivate let result: Payload

		fileprivate init(
			untrustedData: Bool,
			result: Payload
		) {
			self.untrustedData = untrustedData
			self.result = result
		}
	}

	private struct Payload: Decodable {
		fileprivate let kind: String
		fileprivate let items: [AutomationInventoryItem]?
		fileprivate let nextCursor: String?
		fileprivate let operationID: UUID?
		fileprivate let status: AutomationCommandResult.Status?
		fileprivate let targetID: UUID?
		fileprivate let presentations: [AutomationPresentation]?
		fileprivate let presentation: AutomationPresentation?
		fileprivate let code: AutomationFailure?

		fileprivate init(
			kind: String,
			items: [AutomationInventoryItem]?,
			nextCursor: String?,
			operationID: UUID?,
			status: AutomationCommandResult.Status?,
			targetID: UUID?,
			presentations: [AutomationPresentation]?,
			presentation: AutomationPresentation?,
			code: AutomationFailure?
		) {
			self.kind = kind
			self.items = items
			self.nextCursor = nextCursor
			self.operationID = operationID
			self.status = status
			self.targetID = targetID
			self.presentations = presentations
			self.presentation = presentation
			self.code = code
		}
	}
}
#endif
