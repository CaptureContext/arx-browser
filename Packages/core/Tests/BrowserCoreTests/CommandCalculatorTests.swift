import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct CommandCalculatorTests {
	@Test(arguments: [
		("12*7.5", "90"),
		("sqrt(2)", "1.41421356237"),
		("15% of 80", "12"),
		("0.1 + 0.2", "0.3"),
		("2 ^ 10", "1024"),
		("2 ** 3 ** 2", "512"),
		("-2^2", "-4"),
		("(1 + 2) × 3 ÷ 4", "2.25"),
		("10 mod 4", "2"),
		("50%", "0.5"),
		("5!", "120"),
		("pi", "3.14159265359"),
		("tau / 2", "3.14159265359"),
		("e^1", "2.71828182846"),
		("max(3, 7) - min(3, 7)", "4"),
		("log(1000) + ln(e) + log2(8)", "7"),
		("atan2(1, 1) * 4", "3.14159265359"),
		("hypot(3, 4)", "5"),
		("1/3", "0.333333333333"),
		("1e3 * 2", "2000"),
		("2^60", "1.15292150461e+18"),
		("1 / 3e12", "3.33333333333e-13"),
		// Small results keep their twelve significant digits.
		("1 / 3e8", "0.00000000333333333333"),
		("-0 * 5", "0"),
		("SQRT(16)", "4"),
	])
	internal func expressionsGiveAResult(
		_ text: String,
		_ expected: String
	) async throws {
		#expect(CommandCalculator.evaluate(text)?.text == expected)
	}

	@Test(arguments: [
		// Ordinary searches and addresses.
		"", "e", "42", "2024", "1e3", "swift.org", "192.168.1.1", "c++", "hello world", "news!",
		"what is 2+2", "localhost:8080",
		// Not finished or not valid.
		"2 +", "(1 + 2", "sqrt 2", "max(1)", "1 / 0", "sqrt(-1)", "171!", "2.5!", "15% of",
		"2 pi",
	])
	internal func otherTextGivesNoResult(_ text: String) async throws {
		#expect(CommandCalculator.evaluate(text) == nil)
	}

	@Test
	internal func theValueIsKeptBesideItsText() async throws {
		let result = try #require(CommandCalculator.evaluate("12*7.5"))
		expectNoDifference(result, .init(value: 90, text: "90"))
		#expect(CommandCalculator.functions.count >= 23)
	}
}

internal struct QuickCreateTests {
	@Test(arguments: [
		("new doc", ["docs.new", "word.new"]),
		("create sheet", ["sheets.new", "excel.new"]),
		("new meeting", ["meet.new", "cal.new"]),
		("new issue", ["linear.new", "jira.new"]),
		("New Repo", ["repo.new"]),
		("new pres", ["slides.new", "powerpoint.new"]),
		("new figj", ["figjam.new"]),
	])
	internal func requestsListMatchingTargets(
		_ text: String,
		_ hosts: [String]
	) async throws {
		expectNoDifference(QuickCreate.targets(for: text).map(\.host), hosts)
	}

	@Test
	internal func aVerbAloneListsEveryTarget() async throws {
		expectNoDifference(QuickCreate.targets(for: "new").map(\.host), QuickCreate.targets.map(\.host))
		expectNoDifference(QuickCreate.targets(for: " create ").count, QuickCreate.targets.count)
		#expect(QuickCreate.targets.count == 17)
		#expect(Set(QuickCreate.targets.map(\.host)).count == QuickCreate.targets.count)
	}

	@Test
	internal func bareNewDomainsAreRecognised() async throws {
		expectNoDifference(QuickCreate.targets(for: "docs.new").map(\.title), ["Google Docs document"])
		let other = try #require(QuickCreate.targets(for: "Excalidraw.new").first)
		#expect(other.host == "excalidraw.new")
		#expect(other.url == URL(string: "https://excalidraw.new"))
		for text in [".new", "-x.new", "a b.new", "docs.new/path", "docs.news"] {
			#expect(QuickCreate.targets(for: text).isEmpty, "\(text)")
		}
	}

	@Test
	internal func otherTextCreatesNothing() async throws {
		for text in ["news", "renew doc", "new york times", "doc", "newdoc"] {
			#expect(QuickCreate.targets(for: text).isEmpty, "\(text)")
		}
	}
}
