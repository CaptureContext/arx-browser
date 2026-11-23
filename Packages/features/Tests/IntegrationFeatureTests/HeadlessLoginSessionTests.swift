import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-596: a headless run without a logged-in GUI session fails before the engine starts.
@Suite(.dependencies)
internal struct HeadlessLoginSessionTests {
	@Test
	internal func noWindowServerSessionFailsAsStartupFailed() {
		#expect(throws: HeadlessFailure.loginSessionUnavailable) {
			try withDependencies {
				$0.loginSession = .init(current: { nil })
			} operation: {
				try HeadlessLoginSession.check()
			}
		}
	}

	@Test
	internal func theLoginWindowBeforeAnyoneLogsInFails() {
		#expect(throws: HeadlessFailure.loginSessionUnavailable) {
			try withDependencies {
				$0.loginSession = .init(current: { .init(isLoginDone: false, isOnConsole: true) })
			} operation: {
				try HeadlessLoginSession.check()
			}
		}
	}

	@Test(arguments: [true, false])
	internal func aLoggedInSessionRunsWithOrWithoutTheConsole(isOnConsole: Bool) throws {
		try withDependencies {
			$0.loginSession = .init(current: { .init(isLoginDone: true, isOnConsole: isOnConsole) })
		} operation: {
			try HeadlessLoginSession.check()
		}
	}

	@Test
	internal func theFailureSaysWhatIsMissingAndWhereToRead() {
		let failure: HeadlessFailure = .loginSessionUnavailable
		#expect(failure.code == "startupFailed")
		#expect(failure.exitCode == 70)
		#expect(failure.message.contains("needs a logged-in macOS session"))
		#expect(failure.message.contains("DEVELOPMENT.md › Headless runs"))
	}

	@Test
	internal func theDiagnosticNamesWhatTheProbeSaw() {
		expectNoDifference(
			HeadlessLoginSession.diagnostic(nil),
			"ARX_HEADLESS_SESSION windowServer=false"
		)
		expectNoDifference(
			HeadlessLoginSession.diagnostic(.init(isLoginDone: true, isOnConsole: false)),
			"ARX_HEADLESS_SESSION windowServer=true loginDone=true console=false"
		)
	}
}
