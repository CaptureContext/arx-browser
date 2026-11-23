import Foundation
import ChromiumEngine
import CustomDump
import Testing

@testable import ChromiumHost

internal struct InspectionSmokeTests {
	@Test
	internal func requiresExactLoopbackFixtureAddress() throws {
		let base = try InspectionSmokeContract.baseURL(URL(string: "http://127.0.0.1:1234/index.html")!)
		expectNoDifference(base.absoluteString, "http://127.0.0.1:1234/")
	}

	@Test(arguments: [
		"https://127.0.0.1:1234/index.html",
		"http://capturecontext.dev:1234/index.html",
		"http://127.0.0.1/index.html",
		"http://127.0.0.1:1234/inspection/main",
		"http://user:secret@127.0.0.1:1234/index.html",
		"http://127.0.0.1:1234/index.html?unowned=1",
		"http://127.0.0.1:1234/index.html#unowned",
	])
	internal func refusesUnownedAddresses(_ value: String) {
		#expect(throws: InspectionSmokeContract.Failure.invalidFixture) {
			try InspectionSmokeContract.baseURL(URL(string: value)!)
		}
	}

	@Test
	internal func verifiesPositiveShadowContentAndUniqueNamedReference() throws {
		try InspectionSmokeContract.verify(snapshot())
		expectNoDifference(
			try InspectionSmokeContract.reference(in: snapshot(), named: InspectionSmokeContract.buttonName),
			"owned-reference"
		)
		#expect(throws: InspectionSmokeContract.Failure.missingSemantics) {
			try InspectionSmokeContract.verify(snapshot(includeShadow: false))
		}
		#expect(throws: InspectionSmokeContract.Failure.missingReference) {
			try InspectionSmokeContract.verify(snapshot(duplicateButton: true))
		}
	}

	@Test(arguments: InspectionSmokeContract.plainButtonNames)
	internal func requiresEveryPlainButtonNamedByItsOwnWords(_ name: String) throws {
		expectNoDifference(
			try InspectionSmokeContract.reference(in: snapshot(), named: name),
			"plain-\(name)"
		)
		#expect(throws: InspectionSmokeContract.Failure.missingReference) {
			try InspectionSmokeContract.verify(snapshot(withoutPlainButton: name))
		}
	}

	@Test(arguments: InspectionSmokeContract.excluded)
	internal func rejectsEverySecretInNamesAndText(_ secret: String) {
		for inName in [false, true] {
			#expect(throws: InspectionSmokeContract.Failure.privateContent) {
				try InspectionSmokeContract.verify(snapshot(secret: secret, secretInName: inName))
			}
		}
	}

	private func snapshot(
		includeShadow: Bool = true,
		duplicateButton: Bool = false,
		withoutPlainButton missing: String? = nil,
		secret: String? = nil,
		secretInName: Bool = false
	) -> ChromiumInspectionSnapshot {
		let button = ChromiumInspectionNode(
			index: 0,
			parent: nil,
			role: "button",
			name: InspectionSmokeContract.buttonName,
			text: nil,
			reference: "owned-reference"
		)
		var nodes = [button]
		if duplicateButton { nodes.append(button) }
		for name in InspectionSmokeContract.plainButtonNames where name != missing {
			nodes.append(.init(
				index: nodes.count,
				parent: nil,
				role: "button",
				name: name,
				text: nil,
				reference: "plain-\(name)"
			))
		}
		let texts = [InspectionSmokeContract.safeText]
		+ (includeShadow ? [InspectionSmokeContract.safeShadowText] : [])
		for text in texts {
			nodes.append(.init(
				index: nodes.count,
				parent: nil,
				role: "staticText",
				name: nil,
				text: text,
				reference: nil
			))
		}
		if let secret {
			nodes.append(.init(
				index: nodes.count,
				parent: nil,
				role: "staticText",
				name: secretInName ? "prefix \(secret) suffix" : nil,
				text: secretInName ? nil : "prefix \(secret) suffix",
				reference: nil
			))
		}
		return .init(
			snapshotID: "snapshot",
			documentID: "document",
			frameID: "frame",
			domVersion: "1",
			nodes: nodes,
			omissions: ChromiumInspectionOmission.allCases
		)
	}
}
