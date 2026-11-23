import BrowserEngineClient
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

@Suite(.dependencies)
@MainActor
internal struct SecurityDataSettingsTests {
	// MARK: - Installed versions

	@Test
	internal func theNewestInstalledVersionIsTheOneInUse() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try install("CertificateRevocation", "9724", in: directory)
		try install("CertificateRevocation", "10012", in: directory)
		try install("PKIMetadata", "3051", in: directory)

		// A version still being unpacked has no manifest yet.
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("PKIMetadata/3052", isDirectory: true),
			withIntermediateDirectories: true
		)
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("SSLErrorAssistant/not-a-version", isDirectory: true),
			withIntermediateDirectories: true
		)

		let components = BrowserSecurityComponent.installed(in: directory)

		#expect(components.map(\.kind) == [.revocationList, .pkiMetadata, .certificateErrorAssistant])
		#expect(components.map(\.version) == ["10012", "3051", nil])
		#expect(components[0].installed != nil)
		#expect(components[2].installed == nil)
	}

	@Test
	internal func versionsCompareNumerically() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try install("SSLErrorAssistant", "7.9", in: directory)
		try install("SSLErrorAssistant", "7.10", in: directory)
		try install("SSLErrorAssistant", "7.10.0.1", in: directory)

		let assistant = BrowserSecurityComponent.installed(in: directory)
			.first { $0.kind == .certificateErrorAssistant }

		#expect(assistant?.version == "7.10.0.1")
	}

	@Test
	internal func aProfileWithoutComponentsListsEachAsMissing() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let components = BrowserSecurityComponent.installed(in: directory)

		#expect(components.count == BrowserSecurityComponent.Kind.allCases.count)
		#expect(components.allSatisfy { $0.version == nil })
	}

	// MARK: - Settings › Developer

	@Test
	internal func theSectionReadsTheVersionsInUse() async {
		let installed: [BrowserSecurityComponent] = [
			.init(kind: .revocationList, version: "10012", installed: Date(timeIntervalSince1970: 0)),
			.init(kind: .pkiMetadata, version: nil, installed: nil),
			.init(kind: .certificateErrorAssistant, version: "7", installed: nil),
		]
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.browserEngine.securityComponents = { installed }
		}

		await store.send(.ui(.loadSecurityComponents))
		await store.receive(\.event.securityComponentsLoaded) {
			$0.securityComponents = installed
		}
	}

	// MARK: - Helpers

	private func temporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("arx-security-data-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	private func install(
		_ component: String,
		_ version: String,
		in directory: URL
	) throws {
		let versionDirectory = directory
			.appendingPathComponent(component, isDirectory: true)
			.appendingPathComponent(version, isDirectory: true)
		try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
		try Data(#"{"version": "\#(version)"}"#.utf8)
			.write(to: versionDirectory.appendingPathComponent("manifest.json"))
	}
}
