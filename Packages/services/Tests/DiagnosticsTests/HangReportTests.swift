import DiagnosticsClient
import Foundation
import Testing
import _TestSupport

/// MetricKit's hang payloads, reduced (DEV-1010), and their place in a problem report.
internal struct HangReportTests {
	@Test
	internal func aHangDiagnosticKeepsItsDurationAndHeaviestStackOnly() throws {
		let reports: [HangReport] = HangReport.diagnostics(fromPayload: Self.diagnosticPayload, received: Date())
		let report: HangReport = try #require(reports.first)

		#expect(reports.count == 1)
		#expect(report.kind == .diagnostic)
		#expect(report.duration == 2.5)
		#expect(report.appVersion == "0.3.0" && report.appBuild == "42" && report.osVersion == "macOS 27.0 (26A425)")
		// Innermost first, along the most-sampled branch.
		#expect(report.frames == [
			.init(module: "libsystem_kernel.dylib", offset: 0x300),
			.init(module: "Arx Framework", offset: 0x2000),
			.init(module: "Arx", offset: 0x100),
		])
		#expect(report.modules.map(\.name) == ["Arx", "Arx Framework", "libsystem_kernel.dylib"])
		#expect(report.modules.first?.uuid == "11111111-2222-3333-4444-555555555555")

		let kept: String = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
		#expect(!kept.contains("bank.example"))
		#expect(!kept.contains("Users"))
		#expect(!kept.contains("regionFormat"))
	}

	@Test
	internal func aMetricPayloadKeepsItsHangHistogram() throws {
		let report: HangReport = try #require(HangReport.histogram(fromPayload: Self.metricPayload, received: Date()))

		#expect(report.kind == .histogram)
		#expect(report.appVersion == "0.3.0")
		#expect(report.date == Date(timeIntervalSince1970: 1_794_700_800))
		#expect(report.buckets == [
			.init(start: 0, end: 250, count: 7),
			.init(start: 250, end: 1000, count: 2),
			.init(start: 1000, end: 5000, count: 1),
		])
		#expect(HangReport.histogram(fromPayload: Data("{\"metaData\":{}}".utf8), received: Date()) == nil)
	}

	@Test
	internal func aPayloadReadAgainIsKeptOnce() throws {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-hangs-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }

		let log: HangReportLog = .init(folder: root)
		let now: Date = .init(timeIntervalSince1970: 1_794_700_800 + 3600)
		let dated: HangReportLog = .init(file: log.file, now: { now })
		for _ in 0 ..< 3 {
			dated.append(HangReport.diagnostics(fromPayload: Self.diagnosticPayload, received: Date()))
			dated.append([try #require(HangReport.histogram(fromPayload: Self.metricPayload, received: Date()))])
		}

		#expect(dated.reports().count == 2)
	}

	@Test
	internal func aRemovedPayloadDeliveredAgainStaysRemoved() throws {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-hangs-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }

		let now: Date = .init(timeIntervalSince1970: 1_794_700_800 + 3600)
		let log: HangReportLog = .init(file: HangReportLog(folder: root).file, now: { now })
		let histogram: HangReport = try #require(HangReport.histogram(fromPayload: Self.metricPayload, received: Date()))
		log.append(HangReport.diagnostics(fromPayload: Self.diagnosticPayload, received: Date()))
		log.append([histogram])
		log.removeAll()

		// The next launch replays macOS's earlier payloads.
		log.append(HangReport.diagnostics(fromPayload: Self.diagnosticPayload, received: Date()))
		log.append([histogram])
		#expect(log.reports().isEmpty)

		// The list of what was taken in holds hashes, nothing a report could be read back from.
		let seen: String = try String(contentsOf: log.seenFile, encoding: .utf8)
		#expect(seen.split(separator: "\n").count == 2)
		#expect(!seen.contains("Arx") && !seen.contains("diagnostic") && !seen.contains("histogram"))

		// A hang macOS reports after the removal is still kept.
		log.append(HangReport.diagnostics(fromPayload: Self.diagnosticPayload(ending: "2026-11-15 00:30:00 +0000"), received: Date()))
		#expect(log.reports().count == 1)
	}

	@Test
	internal func aLogFromBeforeTheListIsRememberedWhenRemoved() throws {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-hangs-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }

		let now: Date = .init(timeIntervalSince1970: 1_794_700_800 + 3600)
		let log: HangReportLog = .init(file: HangReportLog(folder: root).file, now: { now })
		log.append(HangReport.diagnostics(fromPayload: Self.diagnosticPayload, received: Date()))

		// Saved by a version that kept no list.
		try FileManager.default.removeItem(at: log.seenFile)

		log.removeAll()
		log.append(HangReport.diagnostics(fromPayload: Self.diagnosticPayload, received: Date()))
		#expect(log.reports().isEmpty)
	}

	@Test
	internal func reportsPastTheRetentionAreForgotten() throws {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-hangs-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }

		let file: URL = HangReportLog(folder: root).file
		let then: Date = .init(timeIntervalSince1970: 1_794_700_800 + 3600)
		HangReportLog(file: file, now: { then }).append(HangReport.diagnostics(fromPayload: Self.diagnosticPayload, received: Date()))

		let later: HangReportLog = .init(file: file, now: { then.addingTimeInterval(HangReportLog.retention) })
		later.prune()
		#expect(later.reports().isEmpty)
		#expect(try Data(contentsOf: later.seenFile).isEmpty)
	}

	@Test
	internal func diagnosticsCarryRecentStallsAndHangReports() async throws {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-hangs-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }

		let locations: CrashReportStore.Locations = .init(
			reports: root.appendingPathComponent("Crash Reports"),
			systemReports: root.appendingPathComponent("DiagnosticReports"),
			engineDatabase: root.appendingPathComponent("Crashpad")
		)
		let store: CrashReportStore = .init(locations: locations)
		store.stalls.append(.init(id: "recent", date: Date().addingTimeInterval(-60), duration: 1.5))
		store.stalls.append(.init(id: "old", date: Date().addingTimeInterval(-10 * 24 * 3600), duration: 1.5))

		// A payload from an hour ago, whatever today is.
		let formatter: DateFormatter = .init()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
		let recent: String = formatter.string(from: Date().addingTimeInterval(-3600))
		store.hangReports.append(HangReport.diagnostics(fromPayload: Self.diagnosticPayload(ending: recent), received: Date()))
		let client: DiagnosticsClient = .live(store: store)

		let diagnostics: ProblemReport.Diagnostics = await client.diagnostics()
		#expect(diagnostics.stalls?.map(\.id) == ["recent"])
		#expect(diagnostics.hangReports?.count == 1)
		#expect(await client.status().hangs == 3)

		#expect(await client.removeCrashReports().hangs == 0)
		#expect(!FileManager.default.fileExists(atPath: locations.hangs.appendingPathComponent("stalls.jsonl").path))

		// MetricKit delivers the same payload again at the next launch (DEV-1079).
		store.hangReports.append(HangReport.diagnostics(fromPayload: Self.diagnosticPayload(ending: recent), received: Date()))
		#expect(await client.status().hangs == 0)
	}

	@Test
	internal func reportsSavedBeforeStallsStillDecode() throws {
		let json: String = #"{"hardwareModel":"Mac16,10","memoryGB":24,"crashReports":[]}"#
		let diagnostics: ProblemReport.Diagnostics = try JSONDecoder().decode(ProblemReport.Diagnostics.self, from: Data(json.utf8))

		#expect(diagnostics.stalls == nil && diagnostics.hangReports == nil)
	}

	// MARK: - Fixtures

	/// The shape of `MXDiagnosticPayload.jsonRepresentation()`, with fields Arx must never keep.
	private static var diagnosticPayload: Data {
		diagnosticPayload(ending: "2026-11-15 00:00:00 +0000")
	}

	private static func diagnosticPayload(ending end: String) -> Data {
		Data(
		#"""
		{
			"timeStampEnd": "\#(end)",
			"crashDiagnostics": [{"diagnosticMetaData": {"exceptionReason": {"composedMessage": "https://bank.example/account"}}}],
			"hangDiagnostics": [{
				"version": "1.0.0",
				"diagnosticMetaData": {
					"appVersion": "0.3.0",
					"appBuildVersion": "42",
					"osVersion": "macOS 27.0 (26A425)",
					"hangDuration": "2.5 sec",
					"regionFormat": "US",
					"bundleIdentifier": "dev.capturecontext.arx"
				},
				"callStackTree": {
					"callStackPerThread": true,
					"callStacks": [
						{"threadAttributed": false, "callStackRootFrames": [{"binaryName": "Other", "address": 1, "offsetIntoBinaryTextSegment": 0, "sampleCount": 99}]},
						{"threadAttributed": true, "callStackRootFrames": [{
							"binaryName": "Arx", "binaryUUID": "11111111-2222-3333-4444-555555555555",
							"address": 4352, "offsetIntoBinaryTextSegment": 4096, "sampleCount": 10,
							"subFrames": [
								{"binaryName": "/Users/someone/Arx.app/Contents/Frameworks/Arx Framework", "binaryUUID": "AAAAAAAA-2222-3333-4444-555555555555", "address": 73728, "offsetIntoBinaryTextSegment": 65536, "sampleCount": 8,
									"subFrames": [{"binaryName": "libsystem_kernel.dylib", "address": 8960, "offsetIntoBinaryTextSegment": 8192, "sampleCount": 8}]},
								{"binaryName": "AppKit", "address": 5000, "offsetIntoBinaryTextSegment": 4096, "sampleCount": 2}
							]
						}]}
					]
				}
			}]
		}
		"""#.utf8
		)
	}

	/// The shape of `MXMetricPayload.jsonRepresentation()`.
	private static let metricPayload: Data = Data(
		#"""
		{
			"timeStampEnd": "2026-11-15 00:00:00",
			"appVersion": "0.3.0",
			"metaData": {"appBuildVersion": "42", "osVersion": "macOS 27.0 (26A425)", "regionFormat": "US"},
			"applicationResponsivenessMetrics": {
				"histogrammedAppHangTime": {
					"histogramNumBuckets": 3,
					"histogramValue": {
						"1": {"bucketStart": "250 ms", "bucketEnd": "1,000 ms", "bucketCount": 2},
						"0": {"bucketStart": "0 ms", "bucketEnd": "250 ms", "bucketCount": 7},
						"2": {"bucketStart": "1 sec", "bucketEnd": "5 sec", "bucketCount": 1}
					}
				}
			}
		}
		"""#.utf8
	)
}
