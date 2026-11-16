import Foundation

// Pure presentation rules for a live stream, ported from the web admin's
// adminActivityPresentation.ts (through the Android app's StreamPresentation.kt) so the apps and the
// web name a session the same way. Nothing here is localized wording: `StreamFacts` maps these
// results to the strings the rows show.

/// The whole-session bucket (the server's effective_play_method): Direct Play, Remux, Direct Stream, Transcode.
enum StreamMethod: Equatable, Sendable {
    case direct, remux, directStream, transcode, unknown
}

/// One component's decision (the server's video_decision / audio_decision).
enum StreamDecision: Equatable, Sendable {
    case direct, copy, transcode, unknown

    /// The web's normalizeStreamDecision: remux counts as copy; hls and anything else is unknown.
    init(raw: String?) {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines) {
        // "direct play" is how this app's earlier fixtures and its first Streams list spelled it.
        case "direct", "direct play": self = .direct
        case "copy", "remux": self = .copy
        case "transcode": self = .transcode
        default: self = .unknown
        }
    }
}

enum ToneMap: Equatable, Sendable {
    case hardware, software
}

/// What does the video work (the web's formatTranscodeModeSummary).
enum TranscodeMode: Equatable, Sendable {
    case hardware(String)
    case software
    case pending
    case unknown
    /// Only the audio is re-encoded, so there is no video encoder mode to name.
    case audioOnly
}

/// What the source file holds and what is delivered: "HEVC 4K" and, when it is converted, "H.264 1080p".
struct MediaFlow: Equatable, Sendable {
    var source: String?
    var target: String?

    /// "Source → target" when both are known, otherwise whichever one is.
    var text: String? {
        if let source, let target { return "\(source) → \(target)" }
        return target ?? source
    }
}

enum RouteRole: Equatable, Sendable {
    case transcode, proxy, server, node
}

/// One node a stream passes through; a nil name means the local server.
struct RouteNode: Equatable, Sendable {
    var role: RouteRole
    var name: String?
}

extension String {
    /// The trimmed text, or nil when blank.
    var cleaned: String? { Optional(self).cleaned }
}

extension Optional where Wrapped == String {
    /// The trimmed text, or nil when absent or blank.
    var cleaned: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Decisions and method

extension AdminSession {
    var videoStreamDecision: StreamDecision {
        StreamDecision(raw: videoDecision.cleaned ?? playMethod)
    }

    var audioStreamDecision: StreamDecision {
        StreamDecision(raw: audioDecision.cleaned ?? (transcodeAudio == true ? "transcode" : playMethod))
    }

    /// The server's effective_play_method when it sends one (its closed vocabulary is direct, remux,
    /// direct_stream — "audio" in older builds — and transcode); otherwise the web's local reduction
    /// of the two component decisions.
    var streamMethod: StreamMethod {
        if let value = effectivePlayMethod.cleaned {
            switch value {
            case "direct": return .direct
            case "remux": return .remux
            case "direct_stream", "audio": return .directStream
            case "transcode": return .transcode
            default: return .unknown
            }
        }
        let video = videoStreamDecision
        let audio = audioStreamDecision
        if video == .transcode { return .transcode }
        if audio == .transcode && video != .unknown { return .directStream }
        if video == .direct && audio == .direct { return .direct }
        if video == .copy || audio == .copy { return .remux }
        return .unknown
    }
}

// MARK: - Titles and people

extension AdminSession {
    private var isEpisode: Bool {
        seriesName.cleaned != nil && seasonNumber != nil && episodeNumber != nil
    }

    /// "Series · S2E3 · Episode name" for an episode, the media title for anything else.
    var streamTitle: String {
        guard isEpisode, let series = seriesName.cleaned, let season = seasonNumber, let episode = episodeNumber else {
            return mediaTitle
        }
        let name = episodeName.cleaned ?? mediaTitle.cleaned.flatMap { $0 == series ? nil : $0 }
        return [series, "S\(season)E\(episode)", name].compactMap { $0 }.joined(separator: " · ")
    }

    /// "user · profile"; the profile is left out when the server did not name it or it repeats the user.
    var streamUserLabel: String {
        let profile = profileName.cleaned.flatMap { $0.caseInsensitiveCompare(username) == .orderedSame ? nil : $0 }
        return [username.cleaned, profile].compactMap { $0 }.joined(separator: " · ")
    }

    /// The web's getSessionClientLabel: the server's own label, else name and version, else the name.
    var streamClientLabel: String? {
        if let label = clientLabel.cleaned { return label }
        let name = clientName.cleaned
        if let name, let version = clientVersion.cleaned { return "\(name) \(version)" }
        return name
    }

    /// The exact client identity for the details: version, build and channel when the server sent them.
    var streamClientLabelFull: String? {
        clientLabelFull.cleaned ?? streamClientLabel
    }

    /// The device the player declared, as a readable platform name.
    var streamDeviceLabel: String? {
        guard let platform = devicePlatform.cleaned else { return nil }
        return Self.platformLabels[platform.lowercased()] ?? platform
    }

    /// "Client app · device", whichever the player reported.
    var streamClientLine: String? {
        let line = [streamClientLabel, streamDeviceLabel].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    private static let platformLabels: [String: String] = [
        "android": "Android", "ios": "iOS", "ipados": "iPadOS", "tvos": "tvOS", "macos": "macOS",
        "windows": "Windows", "linux": "Linux", "web": "Web", "androidtv": "Android TV", "tizen": "Tizen",
        "webos": "webOS", "roku": "Roku",
    ]
}

// MARK: - Formatting

enum StreamFormat {
    // MARK: Time

    /// 754 → "12:34"; 3723 → "1:02:03". Negative and non-finite values read as zero.
    static func playbackClock(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds, rounding: .down)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%ld:%02ld:%02ld", hours, minutes, secs) }
        return String(format: "%ld:%02ld", minutes, secs)
    }

    /// Time left, compact: "1h 5m", "32m", "45s". Seconds round up, so a stream with a moment left
    /// does not read "0s".
    static func remainingTime(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds, rounding: .up)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if total >= 60 { return "\(minutes)m" }
        return "\(total)s"
    }

    private static func wholeSeconds(_ seconds: Double, rounding: FloatingPointRoundingRule) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 1e9).rounded(rounding))
    }

    /// The seconds left, or nil when the file's length is unknown.
    static func remainingSeconds(position: Double, duration: Double?) -> Double? {
        guard let length = duration, length > 0 else { return nil }
        return max(length - position, 0)
    }

    /// Where playback is now: the last reported position plus the time since that report while it
    /// plays, held at the report while it is paused, never past the end of the file.
    static func projectedPosition(position: Double, duration: Double?, paused: Bool, elapsed: TimeInterval) -> Double {
        let base = position.isNaN || position < 0 ? 0 : position
        let moved = paused || elapsed <= 0 ? base : base + elapsed
        guard let length = duration, length > 0 else { return moved }
        return min(moved, length)
    }

    /// 0...1 progress, or nil when the file's length is unknown.
    static func progressFraction(position: Double, duration: Double?) -> Double? {
        guard let length = duration, length > 0 else { return nil }
        return min(max(position / length, 0), 1)
    }

    /// A server timestamp in the device's zone ("Nov 13, 2026 at 2:02 PM"), or nil if absent or unparseable.
    static func instant(_ iso: String?, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let text = iso.cleaned, let date = parseInstant(text) else { return nil }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: locale.calendar, timeZone: timeZone))
    }

    /// The server writes RFC 3339 with up to nanosecond digits; whole seconds are all a row shows.
    private static func parseInstant(_ text: String) -> Date? {
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }

    // MARK: Media

    private static let codecLabels: [String: String] = [
        "aac": "AAC", "ac3": "AC3", "av1": "AV1", "dts": "DTS", "dtshd": "DTS-HD", "eac3": "EAC3",
        "flac": "FLAC", "h264": "H.264", "hevc": "HEVC", "mp3": "MP3", "opus": "Opus", "truehd": "TrueHD",
        "h265": "HEVC", "avc": "H.264",
    ]

    /// The web's formatCodecLabel: known codecs by name, any other upper-cased; nil when blank.
    static func codec(_ codec: String?) -> String? {
        guard let value = codec.cleaned else { return nil }
        return codecLabels[value.lowercased()] ?? value.uppercased()
    }

    /// "2160p" and "3840x2160" read "4K", "1920x1080" and "1080p" read "1080p"; anything else passes through.
    static func resolution(_ resolution: String?) -> String? {
        guard let value = resolution.cleaned else { return nil }
        let lower = value.lowercased()
        if lower == "4k" || lower == "uhd" { return "4K" }
        if lower == "8k" { return "8K" }
        if let height = heightP(lower) { return heightLabel(height) }
        if let (width, height) = widthByHeight(lower) {
            // A 3840x1600 file is a 4K title; the catalog sizes by the wider edge too.
            return width >= 7680 ? "8K" : width >= 3840 ? "4K" : heightLabel(height)
        }
        return value
    }

    /// The height in "1080p" (three or four digits), or nil.
    static func heightP(_ lowercased: String) -> Int? {
        guard lowercased.hasSuffix("p") else { return nil }
        let digits = lowercased.dropLast()
        guard (3...4).contains(digits.count), digits.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(digits)
    }

    private static func widthByHeight(_ lowercased: String) -> (Int, Int)? {
        let parts = lowercased.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ (3...5).contains($0.count) && $0.allSatisfy(\.isASCIIDigit) }),
              let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return (width, height)
    }

    private static func heightLabel(_ height: Int) -> String {
        height >= 4320 ? "8K" : height >= 2160 ? "4K" : "\(height)p"
    }

    /// 1 → "1.0", 2 → "2.0", 6 → "5.1", 8 → "7.1", other counts "Nch"; nil when unknown.
    static func channelLayout(_ channels: Int?) -> String? {
        guard let channels, channels > 0 else { return nil }
        switch channels {
        case 1: return "1.0"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    /// "8.2 Mbps" from 1,000 kbps up, "850 kbps" below; nil for a missing or non-positive rate.
    static func bitrate(_ kbps: Int?, locale: Locale = .current) -> String? {
        guard let kbps, kbps > 0 else { return nil }
        if kbps >= 1000 { return String(format: "%.1f Mbps", locale: locale, Double(kbps) / 1000) }
        return "\(kbps) kbps"
    }

    /// The track's language as a readable name ("en" → "English"); the raw tag when the device cannot name it.
    static func audioLanguage(_ tag: String?, locale: Locale = .current) -> String? {
        guard let value = tag.cleaned else { return nil }
        let code = Locale(identifier: value.replacingOccurrences(of: "_", with: "-")).language.languageCode?.identifier
        guard let code, let name = locale.localizedString(forLanguageCode: code)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty, name.caseInsensitiveCompare(code) != .orderedSame else { return value }
        return name
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Media flows and transcode details

extension AdminSession {
    /// The web keeps the source's size class when a transcode targets the source's own height (a
    /// 3840x1600 file is "2160p", its full-height output "1600p"), so a full-size output does not
    /// read as a downscale.
    private var deliveredResolution: String? {
        guard let target = targetResolution.cleaned else { return nil }
        if let sourceHeight = sourceVideoHeight, sourceHeight > 0,
           StreamFormat.heightP(target.lowercased()) == sourceHeight,
           let source = StreamFormat.resolution(sourceVideoResolution) {
            return source
        }
        return StreamFormat.resolution(target)
    }

    private static func join(_ parts: String?...) -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " ")
    }

    var videoFlow: MediaFlow {
        let source = Self.join(StreamFormat.codec(sourceVideoCodec), StreamFormat.resolution(sourceVideoResolution))
        let target = videoStreamDecision == .transcode ? Self.join(StreamFormat.codec(targetVideoCodec), deliveredResolution) : nil
        return MediaFlow(source: source, target: target)
    }

    /// The target channel layout is shown only when the server reported it; the source layout is never reused.
    var audioFlow: MediaFlow {
        let source = Self.join(StreamFormat.codec(sourceAudioCodec), StreamFormat.channelLayout(sourceAudioChannels))
        let target = audioStreamDecision == .transcode
            ? Self.join(StreamFormat.codec(targetAudioCodec ?? "aac"), StreamFormat.channelLayout(targetAudioChannels))
            : nil
        return MediaFlow(source: source, target: target)
    }

    /// Nil when nothing is being transcoded.
    var transcodeMode: TranscodeMode? {
        let video = videoStreamDecision == .transcode
        let audio = audioStreamDecision == .transcode
        guard video || audio else { return nil }
        guard video else { return .audioOnly }
        switch transcodeHWAccel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "": return .unknown
        case "none": return .software
        case "auto": return .pending
        case "qsv": return .hardware("QSV")
        case "vaapi": return .hardware("VAAPI")
        case "videotoolbox": return .hardware("VideoToolbox")
        case let accel?: return .hardware(accel.uppercased())
        }
    }

    /// HDR-to-SDR tone mapping, only for a transcoded video and only when the server confirmed the executor.
    var toneMap: ToneMap? {
        guard videoStreamDecision == .transcode else { return nil }
        switch toneMapMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hardware": return .hardware
        case "software": return .software
        default: return nil
        }
    }
}

// MARK: - Delivery and route

extension AdminSession {
    /// The source container, upper-cased ("MKV").
    var sourceContainerLabel: String? { sourceContainer.cleaned?.uppercased() }

    /// The container the stream is delivered in: the source's own for a direct play, else what the
    /// serving node reported ("fMP4", "MPEG-TS" or its upper-cased name), with "HLS" when it is
    /// served over that protocol. Nil when nothing was reported.
    var deliveredContainerLabel: String? {
        if playMethod.trimmingCharacters(in: .whitespacesAndNewlines) == "direct" { return sourceContainerLabel }
        let container: String? = outputContainer.cleaned.map { raw in
            switch raw.lowercased() {
            case "fmp4": "fMP4"
            case "mpegts": "MPEG-TS"
            default: raw.uppercased()
            }
        }
        let hls = outputProtocol.cleaned == "hls"
        switch (container, hls) {
        case let (container?, true): return "HLS · \(container)"
        case let (container?, false): return container
        case (nil, true): return "HLS"
        case (nil, false): return nil
        }
    }

    /// The nodes that serve the stream, work first, following the web's getSessionRouteNodes.
    var routeNodes: [RouteNode] {
        let execution = routingExecution.cleaned
        let egress = routingEgress.cleaned
        func server() -> RouteNode {
            let reported = reportingNode.cleaned
            return RouteNode(role: .server, name: reported.flatMap { $0.lowercased() == "local" ? nil : $0 })
        }
        if routingWorkload.cleaned == nil, execution == nil, egress == nil {
            let reported = nodeDisplayName.cleaned ?? reportingNode.cleaned
            return [RouteNode(role: .node, name: reported.flatMap { $0.lowercased() == "local" ? nil : $0 })]
        }
        var nodes: [RouteNode] = []
        let executionName = routingExecutionNodeName.cleaned ?? nodeDisplayName.cleaned
        if execution == "transcode" {
            nodes.append(RouteNode(role: .transcode, name: executionName))
        } else if execution == "proxy" {
            nodes.append(RouteNode(role: .proxy, name: executionName))
        }
        if egress == "proxy" {
            let egressNode = RouteNode(role: .proxy, name: routingEgressNodeName.cleaned)
            if !nodes.contains(egressNode) { nodes.append(egressNode) }
        }
        if egress == "api" || (execution == "api" && nodes.isEmpty) { nodes.append(server()) }
        return nodes.isEmpty ? [server()] : nodes
    }
}
