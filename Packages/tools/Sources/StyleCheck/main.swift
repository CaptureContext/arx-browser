import Dispatch
import Foundation
import StyleChecker

// StyleCheck [--github] [--list-rules] PATH...
//
// Prints one warning per finding and exits 0 whatever it finds: the checks are advisory.
// It exits 2 only when it can't run as asked (an unknown option, or no path).

private let usage: String = """
	usage: StyleCheck [--github] PATH...
	       StyleCheck --list-rules

	Checks Swift files, or every .swift file under a directory (skipping .build, build, Forks
	and hidden directories), against the swift-style rules that can be decided mechanically.
	--github prints GitHub workflow annotations instead of path:line:column warnings.
	"""

private var format: StyleOutputFormat = .plain
private var paths: [String] = []

for argument in CommandLine.arguments.dropFirst() {
	switch argument {
	case "--github":
		format = .github

	case "--list-rules":
		for rule in StyleRule.all {
			print("\(rule.id)\t\(rule.section)\t\(rule.summary)")
		}
		exit(0)

	case "-h", "--help":
		print(usage)
		exit(0)

	default:
		if argument.hasPrefix("-") {
			FileHandle.standardError.write(Data("StyleCheck: unknown option \(argument)\n\(usage)\n".utf8))
			exit(2)
		}
		paths.append(argument)
	}
}

guard !paths.isEmpty else {
	FileHandle.standardError.write(Data("\(usage)\n".utf8))
	exit(2)
}

private let skippedDirectories: Set<String> = [".build", "build", "Forks"]

/// Swift files named directly, plus those under named directories.
private func swiftFiles(in paths: [String]) -> [String] {
	let manager: FileManager = .default
	var files: [String] = []

	for path in paths {
		var isDirectory: ObjCBool = false
		guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
			FileHandle.standardError.write(Data("StyleCheck: no such file: \(path)\n".utf8))
			continue
		}

		guard isDirectory.boolValue else {
			files.append(path)
			continue
		}

		guard let enumerator = manager.enumerator(atPath: path) else { continue }

		while let relative = enumerator.nextObject() as? String {
			let name: String = (relative as NSString).lastPathComponent
			let isSkippedDirectory: Bool = enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
			&& (name.hasPrefix(".") || skippedDirectories.contains(name))

			if isSkippedDirectory {
				enumerator.skipDescendants()
			} else if name.hasSuffix(".swift") {
				files.append((path as NSString).appendingPathComponent(relative))
			}
		}
	}

	return files.sorted()
}

private let files: [String] = swiftFiles(in: paths)
private let results: UnsafeMutableBufferPointer<[StyleFinding]> = .allocate(capacity: files.count)
results.initialize(repeating: [])

// Each iteration writes only its own slot.
private nonisolated(unsafe) let slots: UnsafeMutableBufferPointer<[StyleFinding]> = results

DispatchQueue.concurrentPerform(iterations: files.count) { index in
	let path: String = files[index]

	do {
		let source: String = try String(contentsOfFile: path, encoding: .utf8)
		slots[index] = StyleChecker.check(source: source, path: path)
	} catch {
		FileHandle.standardError.write(Data("StyleCheck: can't read \(path): \(error.localizedDescription)\n".utf8))
	}
}

private var counts: [String: Int] = [:]

for findings in results {
	for finding in findings {
		print(finding.formatted(format))
		counts[finding.rule.id, default: 0] += 1
	}
}

private let total: Int = counts.values.reduce(0, +)
private let summary: String = StyleRule.all
	.compactMap { rule in counts[rule.id].map { "\(rule.id) \($0)" } }
	.joined(separator: ", ")

FileHandle.standardError.write(Data(
	"StyleCheck: \(total) findings in \(files.count) files\(summary.isEmpty ? "" : ": \(summary)")\n".utf8
))

results.deallocate()
