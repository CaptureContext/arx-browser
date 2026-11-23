import Foundation
import GRDB
import HistoryDatabase
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync

/// The CloudKit schema in `CloudKit/arx.ckdb` holds every synced table and column (DEV-1209).
///
/// On 18 November 2026 a Release Arx turned sync on against a Production container without Arx's
/// record types: CloudKit refused every save, and the library dropped the refusals without a word.
/// Production only gets the record types and fields someone deploys, so the release deploys this file
/// (DEVELOPMENT.md › iCloud schema). A migration that adds a synced table or column fails here until
/// the file has it: `make cloudkit-schema` writes it again from the code.
@Suite(.timeLimit(.minutes(1)))
struct CloudKitSchemaTests {
	/// `CloudKit/arx.ckdb` at the repository's root.
	private static let schemaFile: URL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent() // WorkspaceSyncTests
		.deletingLastPathComponent() // Tests
		.deletingLastPathComponent() // services
		.deletingLastPathComponent() // Packages
		.deletingLastPathComponent()
		.appendingPathComponent("CloudKit/arx.ckdb")

	@Test
	func everySyncedTableAndColumnIsInTheSchemaFile() throws {
		let expected: CloudKitSchema = try Self.schemaOfTheCode()
		let text: String = try String(contentsOf: Self.schemaFile, encoding: .utf8)
		let file: CloudKitSchema = try .init(parsing: text)

		if ProcessInfo.processInfo.environment["ARX_RECORD_CLOUDKIT_SCHEMA"] == "1" {
			// Fields CloudKit has can't be removed, so the file keeps what it had.
			let merged: CloudKitSchema = file.merging(expected)
			try merged.text.write(to: Self.schemaFile, atomically: true, encoding: .utf8)
			return
		}

		for (name, recordType) in expected.recordTypes.sorted(by: { $0.key < $1.key }) {
			guard let written = file.recordTypes[name] else {
				Issue.record("CloudKit/arx.ckdb has no record type \(name): run `make cloudkit-schema`")
				continue
			}

			for (field, type) in recordType.fields.sorted(by: { $0.key < $1.key }) {
				#expect(
					written.fields[field] == type,
					"CloudKit/arx.ckdb: \(name).\(field) should be \(type), is \(written.fields[field] ?? "missing"): run `make cloudkit-schema`"
				)
			}
			#expect(written.grants == recordType.grants, "CloudKit/arx.ckdb: \(name)'s grants changed")
		}
	}

	@Test
	func theSchemaFileParsesAndRendersAsCloudKitExportsIt() throws {
		let text: String = try String(contentsOf: Self.schemaFile, encoding: .utf8)
		let file: CloudKitSchema = try .init(parsing: text)

		#expect(file.text == text)
		#expect(file.recordTypes["Users"] != nil)
	}

	/// What SQLiteData sends for each synced table: every column as an encrypted field, each with its
	/// own modification time, and the record's.
	private static func schemaOfTheCode() throws -> CloudKitSchema {
		let mac: TestMac = try .init(cloud: .init())
		defer { mac.remove() }

		let readers: [(tables: Set<String>, reader: any DatabaseReader)] = [
			(WorkspaceSync.tableNames(.organization), mac.organization),
			(WorkspaceSync.tableNames(.preferences), mac.preferences),
			(WorkspaceSync.tableNames(.history), mac.history.database),
			(WorkspaceSync.tableNames(.archive), mac.archive),
			([DeviceDirectoryRecord.tableName], mac.devices),
		]
		var schema: CloudKitSchema = .init(recordTypes: ["Users": .users])
		for (tables, reader) in readers {
			for table in tables {
				let columns: [(name: String, type: String)] = try reader.read { db in
					try Row.fetchAll(db, sql: "SELECT \"name\", \"type\" FROM pragma_table_info(?)", arguments: [table])
						.map { (name: $0["name"], type: $0["type"]) }
				}
				#expect(!columns.isEmpty, "\(table) has no columns")
				schema.recordTypes[table] = try .synced(columns: columns)
			}
		}
		return schema
	}
}

/// A CloudKit schema in the `.ckdb` language, as `cktool export-schema` writes it.
struct CloudKitSchema: Equatable {
	struct RecordType: Equatable {
		/// Field name to type, such as `ENCRYPTED STRING`. System fields are kept with their quotes.
		var fields: [String: String]
		var grants: [String]

		/// The record type every container has.
		static let users: Self = .init(
			fields: systemFields.merging(["roles": "LIST<INT64>"]) { $1 },
			grants: [#"GRANT WRITE TO "_creator""#, #"GRANT READ TO "_world""#]
		)

		static func synced(columns: [(name: String, type: String)]) throws -> Self {
			struct UnknownColumnType: Error, CustomStringConvertible {
				var column: String
				var type: String
				var description: String { "No CloudKit type for \(column) \(type)" }
			}

			let modificationTime: String = "sqlitedata_icloud_userModificationTime"
			var fields: [String: String] = systemFields
			fields[modificationTime] = "ENCRYPTED INT64"
			for column in columns {
				let type: String
				switch column.type.uppercased() {
				case "TEXT": type = "STRING"
				case "INTEGER": type = "INT64"
				case "REAL": type = "DOUBLE"
				default: throw UnknownColumnType(column: column.name, type: column.type)
				}
				fields[column.name] = "ENCRYPTED \(type)"
				fields["\(modificationTime)_\(column.name)"] = "ENCRYPTED INT64"
			}
			return .init(
				fields: fields,
				grants: [#"GRANT WRITE TO "_creator""#, #"GRANT CREATE TO "_icloud""#, #"GRANT READ TO "_world""#]
			)
		}

		static let systemFields: [String: String] = [
			#""___createTime""#: "TIMESTAMP",
			#""___createdBy""#: "REFERENCE",
			#""___etag""#: "STRING",
			#""___modTime""#: "TIMESTAMP",
			#""___modifiedBy""#: "REFERENCE",
			#""___recordID""#: "REFERENCE",
		]
	}

	var recordTypes: [String: RecordType]

	init(recordTypes: [String: RecordType]) {
		self.recordTypes = recordTypes
	}

	init(parsing text: String) throws {
		struct Malformed: Error, CustomStringConvertible {
			var line: String
			var description: String { "Can't read the schema line \(line)" }
		}

		var recordTypes: [String: RecordType] = [:]
		var current: (name: String, type: RecordType)?
		for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
			let line: String = rawLine.trimmingCharacters(in: .whitespaces)
			if line == "DEFINE SCHEMA" || line.isEmpty { continue }

			if line.hasPrefix("RECORD TYPE "), line.hasSuffix("(") {
				let name: String = line.dropFirst("RECORD TYPE ".count).dropLast().trimmingCharacters(in: .whitespaces)
				current = (name, .init(fields: [:], grants: []))
			} else if line == ");", let finished = current {
				recordTypes[finished.name] = finished.type
				current = nil
			} else if current != nil {
				let entry: String = line.hasSuffix(",") ? String(line.dropLast()) : line
				if entry.hasPrefix("GRANT ") {
					current?.type.grants.append(entry)
				} else {
					let parts = entry.split(separator: " ", maxSplits: 1)
					guard parts.count == 2 else { throw Malformed(line: line) }

					current?.type.fields[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
				}
			} else {
				throw Malformed(line: line)
			}
		}
		self.recordTypes = recordTypes
	}

	/// Every record type and field of both, `other`'s types winning.
	func merging(_ other: Self) -> Self {
		var merged: Self = self
		for (name, recordType) in other.recordTypes {
			merged.recordTypes[name, default: recordType].fields.merge(recordType.fields) { $1 }
			merged.recordTypes[name]?.grants = recordType.grants
		}
		return merged
	}

	/// As `cktool export-schema` writes it: record types and their fields in byte order, system fields
	/// first, types lined up.
	var text: String {
		var lines: [String] = ["DEFINE SCHEMA", ""]
		for (name, recordType) in recordTypes.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
			let names: [String] = recordType.fields.keys.sorted { lhs, rhs in
				let lhsSystem: Bool = lhs.hasPrefix("\"")
				let rhsSystem: Bool = rhs.hasPrefix("\"")
				if lhsSystem != rhsSystem { return lhsSystem }
				return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
			}
			let width: Int = (names.map(\.count).max() ?? 0) + 1
			let entries: [String] = names.map { field in
				field.padding(toLength: width, withPad: " ", startingAt: 0) + recordType.fields[field]!
			} + recordType.grants
			lines.append("    RECORD TYPE \(name) (")
			lines.append(entries.map { "        \($0)" }.joined(separator: ",\n"))
			lines.append("    );")
			lines.append("")
		}
		return lines.joined(separator: "\n")
	}
}
