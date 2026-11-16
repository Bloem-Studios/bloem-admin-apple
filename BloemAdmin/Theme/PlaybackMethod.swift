import SwiftUI

/// The one palette for how a stream is delivered, used by the charts and by the rows: the web admin's chart
/// colors (direct play #5F74EE, direct stream #169E88, transcode #BF7F22). Red is never a play method.
enum PlaybackMethod: Int, CaseIterable, Sendable {
    case directPlay, directStream, transcode

    var name: String {
        switch self {
        case .directPlay: String(localized: "Direct play")
        case .directStream: String(localized: "Direct stream")
        case .transcode: String(localized: "Transcode")
        }
    }

    /// For lines, bars and dots. Text in these colors would miss 4.5:1, so words stay in text colors.
    var color: Color {
        switch self {
        case .directPlay: Color("BloemChartDirectPlay")
        case .directStream: Color("BloemChartDirectStream")
        case .transcode: Color("BloemChartTranscode")
        }
    }

    /// The method a stream's bucket belongs to; a remux counts with direct stream, as in the charts.
    init?(_ method: StreamMethod) {
        switch method {
        case .direct: self = .directPlay
        case .remux, .directStream: self = .directStream
        case .transcode: self = .transcode
        case .unknown: return nil
        }
    }

    /// Only a transcode is lit in a stream's signal path: it is the one step that costs the server something.
    var isLit: Bool { self == .transcode }
}
