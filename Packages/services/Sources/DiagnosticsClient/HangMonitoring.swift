import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// Arx's hang reporting for a run (DEV-1010): the main-thread ``StallWatchdog`` and MetricKit's
/// hang reports, both kept in `…/Diagnostics/Hangs` and read by Report a Problem.
public final class HangMonitoring: @unchecked Sendable {
	public let watchdog: StallWatchdog
	private let subscriber: AnyObject?

	/// Starts both on the main thread. Call it once, from the main thread, before the run loop runs.
	///
	/// In a Debug build `ARX_STALL_INJECT_MS` blocks the main thread that long, once, five
	/// seconds after launch, to check the watchdog by hand.
	@MainActor
	public static func start(
		locations: CrashReportStore.Locations = .standard,
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> HangMonitoring {
		let monitoring: HangMonitoring = .init(locations: locations, environment: environment)

		// Old records leave the disk even in a run with no new ones.
		DispatchQueue.global(qos: .utility).async {
			StallLog(folder: locations.hangs).prune()
			HangReportLog(folder: locations.hangs).prune()
		}
		monitoring.watchdog.start()
		#if DEBUG
		if let milliseconds = environment["ARX_STALL_INJECT_MS"].flatMap(UInt32.init), milliseconds > 0 {
			DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
				usleep(milliseconds * 1000)
			}
		}
		#endif
		return monitoring
	}

	@MainActor
	private init(
		locations: CrashReportStore.Locations,
		environment: [String: String]
	) {
		self.watchdog = .init(
			log: .init(folder: locations.hangs),
			configuration: .init(environment: environment),
			environment: .current()
		)
		#if canImport(MetricKit)
		let subscriber: MetricKitHangSubscriber = .init(log: .init(folder: locations.hangs))
		MXMetricManager.shared.add(subscriber)

		// What macOS handed over before this run subscribed; the log skips what it already holds.
		DispatchQueue.global(qos: .utility).async {
			subscriber.didReceive(MXMetricManager.shared.pastPayloads)
			subscriber.didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
		}
		self.subscriber = subscriber
		#else
		self.subscriber = nil
		#endif
	}
}

#if canImport(MetricKit)
/// Keeps the hang parts of MetricKit's daily payloads, reduced (``HangReport``).
private final class MetricKitHangSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
	private let log: HangReportLog

	internal init(log: HangReportLog) {
		self.log = log
	}

	internal func didReceive(_ payloads: [MXMetricPayload]) {
		// The payload's own end date stands in when its JSON's can't be read.
		let reports: [HangReport] = payloads.compactMap {
			HangReport.histogram(fromPayload: $0.jsonRepresentation(), received: $0.timeStampEnd)
		}
		log.append(reports)
	}

	internal func didReceive(_ payloads: [MXDiagnosticPayload]) {
		let reports: [HangReport] = payloads.flatMap {
			HangReport.diagnostics(fromPayload: $0.jsonRepresentation(), received: $0.timeStampEnd)
		}
		log.append(reports)
	}
}
#endif
