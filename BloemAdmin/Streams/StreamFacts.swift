import Foundation

/// The wording of one stream row, in the user's language, built from the presentation rules in
/// `StreamPresentation.swift`. The row and its VoiceOver description are both made from these
/// strings, so they read the same.
struct StreamFacts: Equatable, Sendable {
    let method: StreamMethod
    let methodLabel: String
    let stateLabel: String
    let videoLine: String?
    let audioLine: String?
    let extrasLine: String?

    init(_ session: AdminSession, locale: Locale = .current) {
        method = session.streamMethod
        methodLabel = Self.label(for: session.streamMethod)
        stateLabel = session.isPaused ? String(localized: "Paused") : String(localized: "Playing")
        let video = Self.dotted([Self.label(for: session.videoStreamDecision), session.videoFlow.text])
        let audio = Self.dotted([
            Self.label(for: session.audioStreamDecision), session.audioFlow.text,
            StreamFormat.audioLanguage(session.sourceAudioLanguage, locale: locale),
        ])
        videoLine = video.map { String(localized: "Video: \($0)") }
        audioLine = audio.map { String(localized: "Audio: \($0)") }
        extrasLine = Self.dotted([
            session.transcodeMode.map { Self.label(for: $0) },
            session.toneMap.map { Self.label(for: $0) },
            StreamFormat.bitrate(session.streamBitrateKbps, locale: locale),
        ])
    }

    /// What VoiceOver says for the whole row. It uses the last reported position, not a ticking
    /// one, so the description does not change under the reader every second.
    func accessibilityDescription(for session: AdminSession) -> String {
        [
            session.streamTitle, session.streamUserLabel, session.streamClientLine, stateLabel, methodLabel,
            Self.progressDescription(position: session.positionSeconds, duration: session.fileDuration),
            videoLine, audioLine, extrasLine,
        ]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// "12:34 of 44:12, 31m left", or "at 12:34" when the file's length is unknown.
    static func progressDescription(position: Double, duration: Double?) -> String {
        guard let duration, duration > 0 else {
            return String(localized: "at \(StreamFormat.playbackClock(position))")
        }
        let left = StreamFormat.remainingTime(StreamFormat.remainingSeconds(position: position, duration: duration) ?? 0)
        return String(localized: "\(StreamFormat.playbackClock(position)) of \(StreamFormat.playbackClock(duration)), \(left) left")
    }

    // MARK: Labels

    static func label(for method: StreamMethod) -> String {
        switch method {
        case .direct: String(localized: "Direct play")
        case .remux: String(localized: "Remux")
        case .directStream: String(localized: "Direct stream")
        case .transcode: String(localized: "Transcode")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// Nil for a decision the server did not make or name.
    static func label(for decision: StreamDecision) -> String? {
        switch decision {
        case .direct: String(localized: "Direct")
        case .copy: String(localized: "Copy")
        case .transcode: String(localized: "Transcode")
        case .unknown: nil
        }
    }

    static func label(for mode: TranscodeMode) -> String {
        switch mode {
        case .hardware(let accel): String(localized: "HW \(accel)")
        case .software: String(localized: "SW")
        case .pending: String(localized: "HW/SW pending")
        case .unknown: String(localized: "HW/SW unknown")
        case .audioOnly: String(localized: "Audio transcode")
        }
    }

    static func label(for toneMap: ToneMap) -> String {
        switch toneMap {
        case .hardware: String(localized: "HW tone map")
        case .software: String(localized: "SW tone map")
        }
    }

    static func dotted(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }
}

// MARK: - Details

/// One labelled line of a row's expanded details.
struct StreamDetailRow: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case method, video, audio, audioTrack, transcoder, container, sourceBitrate, streamBitrate
        case client, node, network, clientIP, started, updated
    }

    let kind: Kind
    let label: String
    let value: String
    var id: String { kind.rawValue }
}

/// The details a row opens to, in the order support reads them. A line with nothing to say is left
/// out; the client address is there only when `showClientIP`, and the playing node and network only
/// when `showServerRouting` (an organization's streams leave the server's routing out).
func streamDetailRows(
    _ session: AdminSession,
    showClientIP: Bool,
    showServerRouting: Bool = true,
    timeZone: TimeZone = .current,
    locale: Locale = .current
) -> [StreamDetailRow] {
    func component(_ decision: StreamDecision, _ flow: MediaFlow, none: String) -> String? {
        // Nothing known about this component at all: leave the line out rather than say so.
        if decision == .unknown && flow.source == nil { return nil }
        let unknownSource = String(localized: "Unknown source")
        let detail: String? = switch decision {
        case .transcode: flow.target.map { String(localized: "Output → \($0)") } ?? String(localized: "Transcoding")
        case .copy: String(localized: "Copied without re-encoding")
        case .direct: none
        case .unknown: nil
        }
        return StreamFacts.dotted([flow.source ?? unknownSource, detail])
    }

    let source = session.sourceContainerLabel
    let delivered = session.deliveredContainerLabel
    let container: String? = switch (source, delivered) {
    case (_, nil): source
    case let (source?, delivered?) where source != delivered: "\(source) → \(delivered)"
    case let (_, delivered?): delivered
    }
    let network: String? = switch session.streamLocation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "local": String(localized: "Local")
    case "remote": String(localized: "Remote")
    default: nil
    }
    let nodes = session.routeNodes.map(nodeLabel).joined(separator: ", ")
    let transcoder = StreamFacts.dotted([
        session.transcodeMode.map { StreamFacts.label(for: $0) },
        session.toneMap.map { StreamFacts.label(for: $0) },
    ])

    let candidates: [(StreamDetailRow.Kind, String, String?)] = [
        (.method, String(localized: "Method"), StreamFacts.label(for: session.streamMethod)),
        (.video, String(localized: "Video"),
         component(session.videoStreamDecision, session.videoFlow, none: String(localized: "No video conversion"))),
        (.audio, String(localized: "Audio"),
         component(session.audioStreamDecision, session.audioFlow, none: String(localized: "No audio conversion"))),
        (.audioTrack, String(localized: "Audio track"), StreamFacts.dotted([
            session.sourceAudioTitle.cleaned, StreamFormat.audioLanguage(session.sourceAudioLanguage, locale: locale),
        ])),
        (.transcoder, String(localized: "Transcoder"), transcoder),
        (.container, String(localized: "Container"), container),
        (.sourceBitrate, String(localized: "Source bitrate"), StreamFormat.bitrate(session.sourceBitrateKbps, locale: locale)),
        (.streamBitrate, String(localized: "Stream bitrate"), StreamFormat.bitrate(session.streamBitrateKbps, locale: locale)),
        (.client, String(localized: "Client"), session.streamClientLabelFull),
        (.node, String(localized: "Playing node"), showServerRouting ? nodes : nil),
        (.network, String(localized: "Network"), showServerRouting ? network : nil),
        (.clientIP, String(localized: "Client IP"), showClientIP ? session.clientIP.cleaned : nil),
        (.started, String(localized: "Started"), StreamFormat.instant(session.startedAt, timeZone: timeZone, locale: locale)),
        (.updated, String(localized: "Last update"), StreamFormat.instant(session.updatedAt, timeZone: timeZone, locale: locale)),
    ]
    return candidates.compactMap { kind, label, value in
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return StreamDetailRow(kind: kind, label: label, value: value)
    }
}

private func nodeLabel(_ node: RouteNode) -> String {
    let role = switch node.role {
    case .transcode: String(localized: "Transcode")
    case .proxy: String(localized: "Proxy")
    case .server: String(localized: "Server")
    case .node: String(localized: "Node")
    }
    return String(localized: "\(role): \(node.name ?? String(localized: "Local server"))")
}
