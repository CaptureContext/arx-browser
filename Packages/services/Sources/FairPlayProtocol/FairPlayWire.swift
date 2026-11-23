import Foundation

/// One JSON object per message, the same shape on every side: `op` for commands, `event` for
/// events, base64 for bytes. Decoding checks ranges and sizes, so a malformed or oversized
/// message reads as nil and is dropped.
private struct Wire: Codable {
	var op: String?
	var event: String?
	var generation: Int?
	var part: Int?
	var parts: Int?
	var playlist: String?
	var certificate: String?
	var ckc: String?
	var spc: String?
	var volume: Double?
	var muted: Bool?
	var time: Double?
	var sequence: Int?
	var duration: Double?
	var playing: Bool?
	var step: FairPlayStep?
	var trace: String?
	var command: FairPlayRemoteCommand?
	var title: String?
	var artist: String?
	var album: String?
	var artwork: String?

	init(
		op: String? = nil,
		event: String? = nil
	) {
		self.op = op
		self.event = event
	}

	var encoded: Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return (try? encoder.encode(self)) ?? Data("{}".utf8)
	}

	static func decode(_ data: Data) -> Self? {
		guard data.count <= FairPlayLimits.maximumLineBytes
		else { return nil }

		return try? JSONDecoder().decode(Self.self, from: data)
	}

	var trackGeneration: Int? {
		generation.flatMap { $0 >= 1 ? $0 : nil }
	}

	var finiteTime: Double? {
		time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
	}

	var unitVolume: Double? {
		volume.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
	}

	var sequenceNumber: Int? {
		sequence.flatMap { $0 >= 0 ? $0 : nil }
	}

	func bytes(_ text: String?, limit: Int) -> Data? {
		guard
			let text,
			text.utf8.count <= (limit * 4 + 2) / 3 + 4,
			let data = Data(base64Encoded: text),
			!data.isEmpty,
			data.count <= limit
		else { return nil }

		return data
	}

	var metadata: FairPlayMetadata {
		FairPlayMetadata(
			title: title ?? "",
			artist: artist ?? "",
			album: album ?? "",
			artwork: artwork.flatMap { URL(string: $0) }
		).bounded
	}

	mutating func set(_ metadata: FairPlayMetadata) {
		title = metadata.title
		artist = metadata.artist
		album = metadata.album
		artwork = metadata.artwork?.absoluteString ?? ""
	}
}

// MARK: - App and helper

extension FairPlayHelperCommand {
	public var encoded: Data {
		var wire: Wire
		switch self {
		case let .load(generation, certificate, playlist, volume, isMuted):
			wire = Wire(op: "load")
			wire.generation = generation
			wire.certificate = certificate.base64EncodedString()
			wire.playlist = playlist
			wire.volume = volume
			wire.muted = isMuted
		case let .license(generation, ckc):
			wire = Wire(op: "license")
			wire.generation = generation
			wire.ckc = ckc.base64EncodedString()
		case .play:
			wire = Wire(op: "play")
		case .pause:
			wire = Wire(op: "pause")
		case let .seek(time, sequence):
			wire = Wire(op: "seek")
			wire.time = time
			wire.sequence = sequence
		case let .volume(volume):
			wire = Wire(op: "volume")
			wire.volume = volume
		case let .muted(isMuted):
			wire = Wire(op: "muted")
			wire.muted = isMuted
		case let .metadata(metadata):
			wire = Wire(op: "metadata")
			wire.set(metadata)
		case .stop:
			wire = Wire(op: "stop")
		}
		return wire.encoded
	}

	public init?(decoding data: Data) {
		guard let wire = Wire.decode(data)
		else { return nil }

		switch wire.op {
		case "load":
			guard
				let generation = wire.trackGeneration,
				let certificate = wire.bytes(wire.certificate, limit: FairPlayLimits.maximumCertificateBytes),
				let playlist = wire.playlist,
				FairPlayPlaylist.isAcceptable(playlist)
			else { return nil }

			self = .load(
				generation: generation,
				certificate: certificate,
				playlist: playlist,
				volume: wire.unitVolume ?? 1,
				isMuted: wire.muted ?? false
			)
		case "license":
			guard
				let generation = wire.trackGeneration,
				let ckc = wire.bytes(wire.ckc, limit: FairPlayLimits.maximumLicenseBytes)
			else { return nil }

			self = .license(generation: generation, ckc: ckc)
		case "play":
			self = .play
		case "pause":
			self = .pause
		case "seek":
			guard
				let time = wire.finiteTime,
				let sequence = wire.sequenceNumber
			else { return nil }

			self = .seek(time: time, sequence: sequence)
		case "volume":
			guard let volume = wire.unitVolume
			else { return nil }

			self = .volume(volume)
		case "muted":
			self = .muted(wire.muted ?? false)
		case "metadata":
			self = .metadata(wire.metadata)
		case "stop":
			self = .stop
		default:
			return nil
		}
	}
}

extension FairPlayHelperEvent {
	public var encoded: Data {
		var wire: Wire
		switch self {
		case let .request(generation, spc):
			wire = Wire(event: "request")
			wire.generation = generation
			wire.spc = spc.base64EncodedString()
		case let .ready(generation, duration):
			wire = Wire(event: "ready")
			wire.generation = generation
			wire.duration = duration
		case let .position(generation, time, isPlaying, sequence):
			wire = Wire(event: "position")
			wire.generation = generation
			wire.time = time
			wire.playing = isPlaying
			wire.sequence = sequence
		case let .ended(generation):
			wire = Wire(event: "ended")
			wire.generation = generation
		case let .failed(generation, step):
			wire = Wire(event: "failed")
			wire.generation = generation
			wire.step = step
		case let .remote(command, time):
			wire = Wire(event: "remote")
			wire.command = command
			wire.time = time
		}
		return wire.encoded
	}

	public init?(decoding data: Data) {
		guard
			let wire = Wire.decode(data),
			let event = wire.event
		else { return nil }

		if event == "remote" {
			guard let command = wire.command
			else { return nil }

			self = .remote(command, time: wire.finiteTime)
			return
		}
		guard let generation = wire.trackGeneration
		else { return nil }

		switch event {
		case "request":
			guard let spc = wire.bytes(wire.spc, limit: FairPlayLimits.maximumLicenseBytes)
			else { return nil }

			self = .request(generation: generation, spc: spc)
		case "ready":
			guard
				let duration = wire.duration,
				duration.isFinite,
				duration > 0
			else { return nil }

			self = .ready(generation: generation, duration: duration)
		case "position":
			guard
				let time = wire.finiteTime,
				let sequence = wire.sequenceNumber
			else { return nil }

			self = .position(generation: generation, time: time, isPlaying: wire.playing ?? false, sequence: sequence)
		case "ended":
			self = .ended(generation: generation)
		case "failed":
			self = .failed(generation: generation, step: wire.step ?? .playback)
		default:
			return nil
		}
	}
}

// MARK: - Page and app

extension FairPlayPageMessage {
	/// The page's message, or nil for anything malformed, oversized or unknown.
	public init?(decoding text: String) {
		guard let wire = Wire.decode(Data(text.utf8))
		else { return nil }

		switch wire.op {
		case "load":
			guard
				let generation = wire.trackGeneration,
				let parts = wire.parts,
				(1...FairPlayLimits.maximumPlaylistParts).contains(parts),
				let part = wire.part,
				(0..<parts).contains(part),
				let playlist = wire.playlist,
				playlist.utf8.count <= FairPlayLimits.maximumPlaylistPartLength
			else { return nil }

			let certificate = part == 0
			? wire.bytes(wire.certificate, limit: FairPlayLimits.maximumCertificateBytes)
			: nil
			if part == 0, certificate == nil { return nil }
			self = .load(
				generation: generation,
				part: part,
				parts: parts,
				playlist: playlist,
				certificate: certificate,
				volume: wire.unitVolume ?? 1,
				isMuted: wire.muted ?? false
			)
		case "license":
			guard
				let generation = wire.trackGeneration,
				let ckc = wire.bytes(wire.ckc, limit: FairPlayLimits.maximumLicenseBytes)
			else { return nil }

			self = .license(generation: generation, ckc: ckc)
		case "play":
			self = .play
		case "pause":
			self = .pause
		case "seek":
			guard
				let time = wire.finiteTime,
				let sequence = wire.sequenceNumber
			else { return nil }

			self = .seek(time: time, sequence: sequence)
		case "volume":
			guard let volume = wire.unitVolume
			else { return nil }

			self = .volume(volume)
		case "muted":
			self = .muted(wire.muted ?? false)
		case "metadata":
			self = .metadata(wire.metadata)
		case "stop":
			self = .stop
		case "failed":
			self = .failed
		case "trace":
			guard let trace = wire.trace.flatMap(FairPlayTrace.init(rawValue:))
			else { return nil }

			self = .trace(trace)
		default:
			return nil
		}
	}
}

extension FairPlayPageEvent {
	/// The event as the page script reads it.
	public var text: String {
		var wire: Wire
		switch self {
		case let .request(generation, spc):
			wire = Wire(event: "request")
			wire.generation = generation
			wire.spc = spc.base64EncodedString()
		case let .ready(generation, duration):
			wire = Wire(event: "ready")
			wire.generation = generation
			wire.duration = duration
		case let .position(generation, time, isPlaying, sequence):
			wire = Wire(event: "position")
			wire.generation = generation
			wire.time = time
			wire.playing = isPlaying
			wire.sequence = sequence
		case let .ended(generation):
			wire = Wire(event: "ended")
			wire.generation = generation
		case let .failed(generation, step):
			wire = Wire(event: "failed")
			wire.generation = generation
			wire.step = step
		case let .stolen(generation):
			wire = Wire(event: "stolen")
			wire.generation = generation
		case let .remote(command, time):
			wire = Wire(event: "remote")
			wire.command = command
			wire.time = time
		}
		return String(decoding: wire.encoded, as: UTF8.self)
	}
}
