import DiagnosticsClient
import Foundation
import Testing
import _TestSupport

/// Reducing macOS crash reports and Chromium minidumps to what's allowed to leave the Mac (DEV-887).
internal struct CrashReportTests {
	internal static let secretURL: String = "https://bank.example/account?token=secret"

	// MARK: - macOS reports

	internal static func ipsReport(
		bundleID: String = "dev.capturecontext.arx",
		name: String = "Arx"
	) -> Data {
		let header: [String: Any] = [
			"app_name": name,
			"app_version": "0.3.0",
			"build_version": "12",
			"bundleID": bundleID,
			"bug_type": "309",
			"incident_id": "6B1F1D35-5A0E-4F9B-9D1E-0B6C1B2E3F40",
			"os_version": "macOS 27.0 (26A425)",
			"timestamp": "2026-11-13 10:01:02.00 +0100",
			"name": name,
		]
		let body: [String: Any] = [
			"procName": name,
			"procPath": "/Users/max/Applications/Arx.app/Contents/MacOS/Arx",
			"userID": 501,
			"crashReporterKey": "ABCDEF-SECRET-KEY",
			"asi": ["libswiftCore.dylib": ["Fatal error: \(secretURL)"]],
			"termination": ["indicator": "Trace/BPT trap: 5", "reasons": [secretURL]],
			"exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP", "subtype": "KERN_INVALID_ADDRESS at 0x1"],
			"faultingThread": 1,
			"threads": [
				["frames": [["imageIndex": 1, "imageOffset": 4, "symbol": "idle"]]],
				[
					"triggered": true,
					"name": "CrBrowserMain",
					"threadState": ["x": [["value": 1234]], "pc": ["value": 99]],
					"frames": [
						["imageIndex": 0, "imageOffset": 1000, "symbol": "BrowserWindow.render()"],
						["imageIndex": 1, "imageOffset": 2000],
						["imageIndex": 9, "imageOffset": 3000],
					],
				],
			],
			"usedImages": [
				["name": "Arx", "uuid": "aaaaaaaa-1111-2222-3333-444444444444", "path": "/Users/max/Applications/Arx.app/Contents/MacOS/Arx"],
				["uuid": "bbbbbbbb-1111-2222-3333-444444444444", "path": "/Users/max/Applications/Arx.app/Contents/Frameworks/Arx Framework.framework/Versions/A/Arx Framework"],
				["name": "Unused", "uuid": "cccccccc-1111-2222-3333-444444444444", "path": "/Users/max/secret/Unused"],
			],
			"vmSummary": "MALLOC … /Users/max/Documents/secret.pdf",
		]
		var data: Data = try! JSONSerialization.data(withJSONObject: header)
		data.append(UInt8(ascii: "\n"))
		data.append(try! JSONSerialization.data(withJSONObject: body))
		return data
	}

	@Test
	internal func aMacOSReportKeepsOnlyTheAllowedFields() throws {
		let report = try #require(
			SystemCrashReport.parse(Self.ipsReport(), fallbackID: "file", fallbackDate: .distantPast)
		)
		#expect(report.id == "6B1F1D35-5A0E-4F9B-9D1E-0B6C1B2E3F40")
		#expect(report.source == .system)
		#expect(report.process == "Arx")
		#expect(report.appVersion == "0.3.0")
		#expect(report.appBuild == "12")
		#expect(report.osVersion == "macOS 27.0 (26A425)")
		#expect(report.exception == "EXC_BREAKPOINT (SIGTRAP)")
		#expect(
			report.frames == [
				.init(module: "Arx", offset: 1000, symbol: "BrowserWindow.render()"),
				.init(module: "Arx Framework", offset: 2000),
			]
		)
		#expect(
			report.modules == [
				.init(name: "Arx", uuid: "AAAAAAAA-1111-2222-3333-444444444444"),
				.init(name: "Arx Framework", uuid: "BBBBBBBB-1111-2222-3333-444444444444"),
			]
		)
		#expect(report.date == Date(timeIntervalSince1970: 1_794_560_462))

		let encoded: String = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
		for forbidden in ["bank.example", "secret", "/Users", "max", "SECRET-KEY", "501", "KERN_INVALID_ADDRESS", "Trace/BPT", "Unused"] {
			#expect(!encoded.contains(forbidden), "\(forbidden)")
		}
	}

	@Test
	internal func helperReportsCountAndOtherAppsDont() {
		let helper = SystemCrashReport.parse(
			Self.ipsReport(bundleID: "dev.capturecontext.arx.helper.renderer", name: "Arx Helper (Renderer)"),
			fallbackID: "file",
			fallbackDate: .distantPast
		)
		#expect(helper?.process == "Arx Helper (Renderer)")
		#expect(SystemCrashReport.parse(Self.ipsReport(bundleID: "com.apple.Safari", name: "Safari"), fallbackID: "x", fallbackDate: .distantPast) == nil)
		#expect(SystemCrashReport.parse(Data("not json".utf8), fallbackID: "x", fallbackDate: .distantPast) == nil)
	}

	// MARK: - Minidumps

	@Test
	internal func aMinidumpKeepsTheExceptionModulesAndReturnAddresses() throws {
		let dump: Data = MinidumpFixture.renderer()
		let report = try #require(Minidump.parse(dump, id: "dump-1", fallbackDate: .distantPast))
		#expect(report.id == "dump-1")
		#expect(report.source == .engine)
		#expect(report.process == "Arx Helper (Renderer)")
		#expect(report.exception == "EXC_BAD_ACCESS (code 1)")
		#expect(report.osVersion == "macOS 27.0.1")
		#expect(report.date == Date(timeIntervalSince1970: 1_794_560_462))
		#expect(
			report.frames == [
				.init(module: "Arx Framework", offset: 0x100), // pc; lr (0x200) isn't trusted with a stack
				.init(module: "Arx Framework", offset: 0x300), // first saved frame
				.init(module: "Arx Helper (Renderer)", offset: 0x40), // second

				// The third return address is outside every module and is dropped.
			]
		)
		#expect(
			report.modules == [
				.init(name: "Arx Framework", uuid: "11223344-5566-7788-99AA-BBCCDDEEFF00"),
				.init(name: "Arx Helper (Renderer)", uuid: nil),
			]
		)

		// The stack holds the page's URL; it never reaches the report.
		#expect(dump.range(of: Data(Self.secretURL.utf8)) != nil)
		let encoded: String = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
		#expect(!encoded.contains("bank.example"))
		#expect(!encoded.contains("/Users"))
	}

	@Test
	internal func truncatedOrForeignFilesGiveNothingOrNoFrames() {
		#expect(Minidump.parse(Data("MDMX".utf8), id: "x", fallbackDate: .distantPast) == nil)
		#expect(Minidump.parse(Data(), id: "x", fallbackDate: .distantPast) == nil)
		let dump: Data = MinidumpFixture.renderer()
		for length in [16, 64, 200, dump.count / 2] {
			// Never crashes on a cut file.
			_ = Minidump.parse(dump.prefix(length), id: "x", fallbackDate: .distantPast)
		}
	}

	@Test
	internal func aFramePointerLoopStops() throws {
		let report = try #require(Minidump.parse(MinidumpFixture.renderer(loop: true), id: "x", fallbackDate: .distantPast))
		#expect(report.frames.count <= CrashReport.frameLimit)
	}
}

// MARK: - Fixture

/// Builds a small arm64 Crashpad-style minidump.
internal enum MinidumpFixture {
	internal static let frameworkBase: UInt64 = 0x1_0000_0000
	internal static let helperBase: UInt64 = 0x1_8000_0000
	internal static let stackStart: UInt64 = 0x16_F000_0000

	internal static func renderer(loop: Bool = false) -> Data {
		var data: Data = .init()
		func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		func pad(to offset: Int) { while data.count < offset { data.append(0) } }
		func set32(
			_ value: UInt32,
			at offset: Int
		) {
			withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + 4, with: $0) }
		}

		// Header and a directory of four streams.
		u32(0x504D_444D); u32(0xA793); u32(4); u32(32); u32(0); u32(1_794_560_462); u64(0)
		let directory: Int = data.count
		pad(to: directory + 4 * 12)

		// Strings and the CodeView record.
		func string(_ text: String) -> Int {
			let offset: Int = data.count
			let units: [UInt16] = Array(text.utf16)
			u32(UInt32(units.count * 2))
			units.forEach(u16)
			return offset
		}
		let frameworkName: Int = string("/Users/max/Applications/Arx.app/Contents/Frameworks/Arx Framework.framework/Versions/147/Arx Framework")
		let helperName: Int = string("/Users/max/Applications/Arx.app/Contents/Frameworks/Arx Framework.framework/Helpers/Arx Helper (Renderer).app/Contents/MacOS/Arx Helper (Renderer)")
		let codeView: Int = data.count
		u32(0x5344_5352); u32(0x1122_3344); u16(0x5566); u16(0x7788)
		data.append(contentsOf: [0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00])
		u32(0); data.append(0)

		// Module list: the helper first, as Crashpad puts the main executable first.
		let modules: Int = data.count
		u32(2)
		for (base, name, cv) in [(helperBase, helperName, 0), (frameworkBase, frameworkName, codeView)] {
			let entry: Int = data.count
			u64(base); u32(0x10_0000); u32(0); u32(0); u32(UInt32(name))
			pad(to: entry + 76)
			u32(cv == 0 ? 0 : 29); u32(UInt32(cv))
			pad(to: entry + 108)
		}

		// The crashed thread's stack: two frame records, then one outside every module.
		let stackBytes: Int = data.count
		let record0: UInt64 = stackStart + 0x10
		let record1: UInt64 = stackStart + 0x30
		let record2: UInt64 = stackStart + 0x50
		pad(to: stackBytes + 0x10)
		u64(record1); u64(frameworkBase + 0x300)
		pad(to: stackBytes + 0x30)
		u64(loop ? record0 : record2); u64(helperBase + 0x40)
		pad(to: stackBytes + 0x50)
		u64(0); u64(0x7000_0000)

		// Page memory on the stack, as a renderer's stack can hold.
		data.append(contentsOf: Array(CrashReportTests.secretURL.utf8))
		pad(to: stackBytes + 0x100)
		let stackSize: Int = data.count - stackBytes

		// The arm64 context at the exception.
		let context: Int = data.count
		pad(to: context + 240)
		u64(record0); u64(frameworkBase + 0x200); u64(stackStart); u64(frameworkBase + 0x100)
		pad(to: context + 912)

		// Thread list.
		let threads: Int = data.count
		u32(1)
		u32(7); u32(0); u32(0); u32(0); u64(0)
		u64(stackStart); u32(UInt32(stackSize)); u32(UInt32(stackBytes))
		u32(912); u32(UInt32(context))

		// Exception stream.
		let exception: Int = data.count
		u32(7); u32(0); u32(1); u32(1); u64(0); u64(0x10); u32(0); u32(0)
		for _ in 0..<15 { u64(0) }
		u32(912); u32(UInt32(context))

		// System info.
		let system: Int = data.count
		u16(12); u16(0); u16(0); data.append(10); data.append(1)
		u32(27); u32(0); u32(1); u32(0x8101); u32(0)
		pad(to: system + 56)

		for (index, (type, offset, size)) in [
			(UInt32(3), threads, 52), (4, modules, 4 + 2 * 108), (6, exception, 168), (7, system, 56),
		].enumerated() {
			set32(type, at: directory + index * 12)
			set32(UInt32(size), at: directory + index * 12 + 4)
			set32(UInt32(offset), at: directory + index * 12 + 8)
		}
		return data
	}
}
