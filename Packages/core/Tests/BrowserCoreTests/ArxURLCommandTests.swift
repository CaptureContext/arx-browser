import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-929: `arx://` automation addresses.
internal struct ArxURLCommandTests {
	@Test
	internal func openTakesAWebPageAndOptionalPlace() async throws {
		let open = try #require(ArxURLCommand(URL(string: "arx://open?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&space=Work&profile=Personal")!))
		expectNoDifference(open, .open(URL(string: "https://example.com/a?b=1")!, space: "Work", profile: "Personal"))
		expectNoDifference(
			ArxURLCommand(URL(string: "ARX://Open?url=http://localhost:3000&little=1")!),
			.littleArx(URL(string: "http://localhost:3000")!, space: nil)
		)
	}

	@Test
	internal func onlyWebPagesAndKnownVerbsComeFromOutside() async throws {
		for text in [
			"arx://open",
			"arx://open?url=file:///etc/hosts",
			"arx://open?url=javascript:alert(1)",
			"arx://open?url=https://user:secret@example.com",
			"arx://little?url=chrome://settings",
			"arx://chat",
			"arx://version",
			"arx://space",
			"https://example.com",
		] {
			#expect(ArxURLCommand(URL(string: text)!) == nil, "\(text)")
		}
		expectNoDifference(ArxURLCommand(URL(string: "arx://little")!), .littleArx(nil, space: nil))
		expectNoDifference(ArxURLCommand(URL(string: "arx://space?name=Work&name=Other")!), .switchSpace("Work"))
	}

	@Test
	internal func spacesAndProfilesResolveByIDOrName() async throws {
		let profile = Profile.ID(rawValue: UUID(0))
		let space = Space(id: .init(rawValue: UUID(1)), profileID: profile, name: "Work")
		let organization = BrowserOrganization(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [space],
			tabs: []
		)
		#expect(organization.space(named: "work")?.id == space.id)
		#expect(organization.space(named: UUID(1).uuidString)?.id == space.id)
		#expect(organization.space(named: "Work", in: .init(rawValue: UUID(9))) == nil)
		#expect(organization.profile(named: "DEFAULT")?.id == profile)
		#expect(organization.profile(named: "Nobody") == nil)
	}
}

extension UUID {
	fileprivate init(_ value: UInt8) {
		self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}
}
