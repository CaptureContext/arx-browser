import Darwin
import Foundation

/// Ends a headless run whose launcher has gone away, so an agent that exits or
/// crashes never leaves a browser behind.
///
/// - The launching process is the parent at startup. Its exit is observed with a
///   kqueue `NOTE_EXIT` source, and a reparented process (`getppid()` changed) is
///   treated the same way, which also covers a parent that exited before the source
///   was installed. A run started by launchd (parent PID 1, e.g. through `open`) has
///   no launcher to watch.
/// - Wrapper chains such as `npx` → `node` → Arx keep the direct parent alive after
///   the outer launcher exits. The process-group leader and the session leader at
///   startup are therefore watched too, when they are neither this process nor its
///   parent and still lead at startup. Either one exiting ends the run. A run that is
///   its own group and session leader, e.g. one started with `setsid`, watches neither.
/// - Standard input is watched only when it is a pipe or socket at startup. Its
///   end-of-file means the launcher closed it or exited; any bytes read are ignored.
///   A terminal, a file or `/dev/null` is never watched, so `</dev/null` keeps a run
///   alive until it is signalled.
@MainActor
internal final class HeadlessLifetime {
	internal enum Ending: String, Equatable, Sendable {
		case parentExited
		case launcherExited
		case inputClosed
	}

	/// A process-group or session leader of the chain that launched the run.
	internal struct Leader: Equatable, Sendable {
		internal enum Kind: Equatable, Sendable {
			case group
			case session
		}

		internal var kind: Kind
		internal var pid: pid_t
	}

	internal let parent: pid_t?
	internal let leaders: [Leader]
	internal let input: Int32?

	/// Whether `parent` and `leaders` were read from this process, so reparenting
	/// means the parent exited and a leader that stopped leading has exited.
	private let watchesCurrentProcess: Bool
	private var sources: [any DispatchSourceProtocol] = []
	private var ended: Bool = false

	/// `parent`, `leaders` and `input` are what to watch; nil or empty skips that check.
	internal convenience init(
		parent: pid_t?,
		leaders: [Leader] = [],
		input: Int32?
	) {
		self.init(parent: parent, leaders: leaders, input: input, watchesCurrentProcess: false)
	}

	private init(
		parent: pid_t?,
		leaders: [Leader],
		input: Int32?,
		watchesCurrentProcess: Bool
	) {
		self.parent = parent
		self.leaders = leaders
		self.input = input
		self.watchesCurrentProcess = watchesCurrentProcess
	}

	/// What this process should watch: its launcher, unless launchd started it, the
	/// leaders of its launcher chain, and standard input, only when it is a pipe or socket.
	internal static func current(parent: pid_t) -> HeadlessLifetime {
		let leaders = watchedLeaders(process: getpid(), parent: parent, group: getpgrp(), session: getsid(0))
		return HeadlessLifetime(
			parent: watchedParent(parent),
			leaders: leaders.filter(stillLeads),
			input: watchesInput(STDIN_FILENO) ? STDIN_FILENO : nil,
			watchesCurrentProcess: true
		)
	}

	internal nonisolated static func watchedParent(_ parent: pid_t) -> pid_t? {
		parent > 1 ? parent : nil
	}

	/// The group and session leaders worth watching, without duplicates. This process
	/// never watches itself, the parent is already watched, and launchd or a failed
	/// lookup (PID 1, 0 or -1) is no launcher.
	internal nonisolated static func watchedLeaders(
		process: pid_t,
		parent: pid_t,
		group: pid_t,
		session: pid_t
	) -> [Leader] {
		var leaders: [Leader] = []
		for leader in [Leader(kind: .group, pid: group), Leader(kind: .session, pid: session)] {
			guard
				leader.pid > 1,
				leader.pid != process,
				leader.pid != parent,
				!leaders.contains(where: { $0.pid == leader.pid })
			else { continue }
			leaders.append(leader)
		}
		return leaders
	}

	/// Whether `leader` still leads its group or session. An exited leader's PID is
	/// gone or, once reused, belongs to a process that leads nothing of ours.
	internal nonisolated static func stillLeads(_ leader: Leader) -> Bool {
		switch leader.kind {
		case .group: getpgid(leader.pid) == leader.pid
		case .session: getsid(leader.pid) == leader.pid
		}
	}

	internal nonisolated static func watchesInput(_ descriptor: Int32) -> Bool {
		var status = stat()
		guard fstat(descriptor, &status) == 0 else { return false }
		let type = status.st_mode & S_IFMT
		return type == S_IFIFO || type == S_IFSOCK
	}

	/// Calls `end` at most once, on the main queue.
	internal func start(_ end: @escaping @MainActor (Ending) -> Void) {
		let finish: @MainActor (Ending) -> Void = { [weak self] ending in
			guard let self, !ended else { return }
			ended = true
			cancel()
			end(ending)
		}

		if let parent {
			let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
			source.setEventHandler {
				MainActor.assumeIsolated { finish(.parentExited) }
			}
			source.resume()
			sources.append(source)

			// The parent may have exited before the source was registered.
			if watchesCurrentProcess ? getppid() != parent : Self.isGone(parent) {
				finish(.parentExited)
				return
			}
		}

		for leader in leaders {
			let source = DispatchSource.makeProcessSource(identifier: leader.pid, eventMask: .exit, queue: .main)
			source.setEventHandler {
				MainActor.assumeIsolated { finish(.launcherExited) }
			}
			source.resume()
			sources.append(source)

			// The leader may have exited before the source was registered.
			if watchesCurrentProcess ? !Self.stillLeads(leader) : Self.isGone(leader.pid) {
				finish(.launcherExited)
				return
			}
		}

		if let input {
			let source = DispatchSource.makeReadSource(fileDescriptor: input, queue: .main)
			source.setEventHandler {
				var buffer = [UInt8](repeating: 0, count: 4096)
				let count = read(input, &buffer, buffer.count)
				guard count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) else { return }
				MainActor.assumeIsolated { finish(.inputClosed) }
			}
			source.resume()
			sources.append(source)
		}
	}

	private nonisolated static func isGone(_ process: pid_t) -> Bool {
		kill(process, 0) != 0 && errno == ESRCH
	}

	internal func cancel() {
		for source in sources { source.cancel() }
		sources.removeAll()
	}
}
