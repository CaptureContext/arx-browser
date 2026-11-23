import Darwin
import Foundation

@main
internal struct AdmissionChecks {
	internal static func reject(_ body: () throws -> ExternalConsentFixture?) {
		do {
			_ = try body()
			preconditionFailure("Malformed fixture admission did not throw")
		} catch {}
	}

	internal static func main() throws {
		let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
		let profile = root.appendingPathComponent("profile")
		let application = root.appending(path: "Arx.app")
		let executable = application.appending(path: "Contents/MacOS/Arx")
		let token = root.appending(path: ".arx-external-consent")
		let config = root.appending(path: "external-consent-fixture.json")
		let argument = ExternalConsentFixture.argument
		let arguments = [executable.path, argument, root.path]
		let environment = ["ARX_EXTERNAL_CONSENT_FIXTURE_ROOT": root.path, "ARX_ENGINE_PROFILE": profile.path]
		let configuration = ExternalConsentFixture.Configuration(application: application)
		try Data(String(repeating: "a", count: 32).utf8).write(to: token)
		try JSONEncoder().encode(configuration).write(to: config)
		for path in [token, config] {
			try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
		}
		let load: ([String: String], [String], URL) throws -> ExternalConsentFixture? = {
			try ExternalConsentFixture.load(environment: $0, arguments: $1, application: $2)
		}
		let ordinary = try load([:], [executable.path], application)
		precondition(ordinary == nil)
		reject { try load(["ARX_EXTERNAL_CONSENT_FIXTURE_ROOT": root.path], arguments, application) }
		reject { try load(environment, [executable.path], application) }
		reject { try load([:], arguments, application) }
		reject { try load(environment, arguments + [argument, root.path], application) }
		reject { try load(environment, [executable.path, argument, root.path + "wrong"], application) }
		reject { try load(environment, ["Arx", argument, root.path], application) }
		var malformed = environment
		malformed["ARX_ENGINE_PROFILE"] = root.appending(path: "ordinary-profile").path
		reject { try load(malformed, arguments, application) }
		malformed["ARX_ENGINE_PROFILE"] = "relative"
		reject { try load(malformed, arguments, application) }
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profile.path)
		reject { try load(environment, arguments, application) }
		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
		try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: token.path)
		reject { try load(environment, arguments, application) }
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
		try Data(String(repeating: "Z", count: 32).utf8).write(to: token)
		reject { try load(environment, arguments, application) }
		try Data(String(repeating: "a", count: 32).utf8).write(to: token)
		let preserved = root.appending(path: "preserved-profile")
		try FileManager.default.moveItem(at: profile, to: preserved)
		try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: preserved)
		reject { try load(environment, arguments, application) }
		try FileManager.default.removeItem(at: profile)
		try FileManager.default.moveItem(at: preserved, to: profile)
		let other = root.appending(path: "Other.app")
		try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
		reject { try load(environment, arguments, other) }
		try JSONEncoder().encode(ExternalConsentFixture.Configuration(application: other)).write(to: config)
		reject { try load(environment, arguments, application) }
		try JSONEncoder().encode(configuration).write(to: config)
		let loaded = try load(environment, arguments, application)
		precondition(loaded?.root == root && loaded?.profile == profile)
		precondition(!FileManager.default.fileExists(atPath: profile.appending(path: "arx-workspace.json").path))
		try Data("one-use".utf8).write(to: root.appending(path: "external-consent.receipt"))
		reject { try load(environment, arguments, application) }
		print("ARX_EXTERNAL_ADMISSION_CHECKS_PASSED")
	}
}
