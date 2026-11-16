import Foundation
import SwiftUI

/// The filters of the Logs page, sent to `GET /api/v2/admin/logs/app`: severity, message text,
/// component, request ID and playback session. Values are trimmed; an empty one is not sent.
struct LogFilter: Equatable, Sendable {
    var level: String
    var q: String
    var component: String
    var requestID: String
    var playbackSessionID: String

    init(level: String = "", q: String = "", component: String = "", requestID: String = "", playbackSessionID: String = "") {
        self.level = level.trimmingCharacters(in: .whitespacesAndNewlines)
        self.q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        self.component = component.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.playbackSessionID = playbackSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The filter a "Logs" or "FFmpeg logs" action opens: one playback session, and for FFmpeg only
    /// the `ffmpeg` component.
    init(focus: LogsFocus) {
        self.init(component: focus.ffmpegOnly ? "ffmpeg" : "", playbackSessionID: focus.playbackSessionID)
    }

    var normalized: LogFilter {
        LogFilter(level: level, q: q, component: component, requestID: requestID, playbackSessionID: playbackSessionID)
    }

    var isEmpty: Bool { normalized == LogFilter() }

    var query: [String: String] {
        let filter = normalized
        let items = [
            "level": filter.level, "q": filter.q, "component": filter.component,
            "request_id": filter.requestID, "playback_session_id": filter.playbackSessionID,
        ]
        return items.filter { !$0.value.isEmpty }
    }
}

/// Logs opened for one playback session: from a stream's menu or a Playback history row.
struct LogsFocus: Equatable, Hashable, Sendable {
    let playbackSessionID: String
    /// True for "FFmpeg logs": only the `ffmpeg` component.
    let ffmpegOnly: Bool
}

/// The severities the server writes, plus "All" (no `level`) and "Warn and error" (the route takes
/// a comma-separated list).
enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all, debug, info, warn, error, warnAndError

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .debug: return "Debug"
        case .info: return "Info"
        case .warn: return "Warn"
        case .error: return "Error"
        case .warnAndError: return "Warn and error"
        }
    }

    /// The `level` query value; empty for `.all`, which the filter leaves out.
    var queryValue: String {
        switch self {
        case .all: ""
        case .warnAndError: "warn,error"
        default: rawValue
        }
    }

    init(queryValue: String) {
        self = Self.allCases.first { $0.queryValue == queryValue } ?? .all
    }
}
