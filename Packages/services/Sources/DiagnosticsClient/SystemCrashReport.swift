import Foundation

/// Reads macOS's crash reports (`.ips`): a JSON header line, then a JSON body.
///
/// Only an allowlist of fields is read. Left out on purpose: application-specific information
/// (`asi`, which can hold a fatal error's message), termination reasons, file paths, VM region
/// summaries, other threads, register state, the parent and responsible processes, and every
/// identifier for the Mac or its user.
public enum SystemCrashReport {
	/// The bundle identifier every Arx process shares as a prefix.
	public static let bundlePrefix: String = "dev.capturecontext.arx"

	/// A crash report for an Arx process, or `nil` for another app's report or one that can't be read.
	public static func parse(
		_ data: Data,
		fallbackID: String,
		fallbackDate: Date
	) -> CrashReport? {
		guard
			let newline = data.firstIndex(of: UInt8(ascii: "\n")),
			let header = object(data[data.startIndex..<newline]),
			let body = object(data[data.index(after: newline)...])
		else { return nil }

		let bundle: String = string(header["bundleID"]) ?? ""
		let name: String = string(header["app_name"]) ?? string(header["name"]) ?? string(body["procName"]) ?? ""
		guard bundle.hasPrefix(bundlePrefix) || name == "Arx" || name.hasPrefix("Arx Helper")
		else { return nil }

		let images: [[String: Any]] = (body["usedImages"] as? [[String: Any]]) ?? []
		let names: [String?] = images.map { image in
			string(image["name"]) ?? string(image["path"]).map(CrashReport.fileName)
		}
		var frames: [CrashReport.Frame] = []
		var used: [Int] = []
		if let thread = crashedThread(body), let entries = thread["frames"] as? [[String: Any]] {
			for entry in entries.prefix(CrashReport.frameLimit) {
				guard
					let index = integer(entry["imageIndex"]),
					index >= 0, index < names.count,
					let module = names[index],
					let offset = integer(entry["imageOffset"]), offset >= 0
				else { continue }

				frames.append(.init(module: module, offset: UInt64(offset), symbol: string(entry["symbol"])))
				if !used.contains(index) { used.append(index) }
			}
		}
		let modules: [CrashReport.Module] = used.compactMap { index in
			names[index].map { .init(name: $0, uuid: string(images[index]["uuid"])?.uppercased()) }
		}

		return CrashReport(
			id: string(header["incident_id"]) ?? string(body["incident"]) ?? fallbackID,
			date: date(string(header["timestamp"]) ?? string(body["captureTime"])) ?? fallbackDate,
			source: .system,
			process: string(body["procName"]) ?? name,
			processID: integer(body["pid"]).map(Int32.init(truncatingIfNeeded:)),
			appVersion: string(header["app_version"]),
			appBuild: string(header["build_version"]),
			osVersion: string(header["os_version"]),
			exception: exception(body["exception"] as? [String: Any]),
			frames: frames,
			modules: modules
		)
	}

	// MARK: - Fields

	private static func crashedThread(_ body: [String: Any]) -> [String: Any]? {
		let threads: [[String: Any]] = (body["threads"] as? [[String: Any]]) ?? []
		if let triggered = threads.first(where: { ($0["triggered"] as? Bool) == true }) {
			return triggered
		}
		guard let index = integer(body["faultingThread"]), index >= 0, index < threads.count
		else { return threads.first }

		return threads[index]
	}

	/// Type and signal; the subtype (an address, or a message) is left out.
	private static func exception(_ value: [String: Any]?) -> String? {
		guard let value, let type = string(value["type"])
		else { return nil }

		guard let signal = string(value["signal"])
		else { return type }

		return "\(type) (\(signal))"
	}

	private static func object(_ data: Data.SubSequence) -> [String: Any]? {
		(try? JSONSerialization.jsonObject(with: Data(data))) as? [String: Any]
	}

	private static func string(_ value: Any?) -> String? {
		guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
		else { return nil }

		return value
	}

	private static func integer(_ value: Any?) -> Int? {
		if let number = value as? NSNumber { return number.intValue }
		return (value as? String).flatMap { Int($0) }
	}

	/// A `.ips` time, such as `2026-11-16 02:12:11.06 +0100`.
	internal static func date(_ value: String?) -> Date? {
		guard let value else { return nil }

		for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss.SSSS Z"] {
			let formatter: DateFormatter = .init()
			formatter.locale = Locale(identifier: "en_US_POSIX")
			formatter.dateFormat = format
			if let date = formatter.date(from: value) { return date }
		}
		return nil
	}
}
