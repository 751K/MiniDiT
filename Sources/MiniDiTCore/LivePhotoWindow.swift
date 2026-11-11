import Foundation

/// A frame-aligned selection and its key photo within the available source video.
public struct LivePhotoWindow: Sendable, Equatable {
    public let start: Double
    public let duration: Double
    public let poster: Double
    public let end: Double
    public var sourcePoster: Double { start + poster }

    /// Initial selection: three seconds around the requested key photo, bounded by the source.
    public init?(videoStart: Double = 0, videoEnd: Double, center: Double, frameRate: Double = 30) {
        guard videoStart.isFinite, videoEnd.isFinite, center.isFinite, frameRate.isFinite,
              videoStart >= 0, videoEnd - videoStart >= 0.5, frameRate > 0 else { return nil }
        let rate = min(frameRate, 60), length = min(3, videoEnd - videoStart)
        let point = max(videoStart, min(center, videoEnd))
        let desired = max(videoStart, min(point - 1.5, videoEnd - length))
        start = max(videoStart, videoStart + floor((desired - videoStart) * rate + 0.000001) / rate)
        duration = length
        end = min(videoEnd, start + length)
        poster = max(0, min(((point - start) * rate).rounded() / rate, max(0, length - 1 / rate)))
    }

    /// Explicit In / Out points. Invalid ranges fail instead of silently reverting to a default.
    public init?(videoStart: Double = 0, videoEnd: Double, selectionStart: Double, selectionEnd: Double,
                 center: Double, frameRate: Double = 30) {
        guard videoStart.isFinite, videoEnd.isFinite, selectionStart.isFinite, selectionEnd.isFinite,
              center.isFinite, frameRate.isFinite, frameRate > 0, videoStart >= 0,
              videoEnd - videoStart >= 0.5, selectionStart >= videoStart - 0.000001,
              selectionEnd <= videoEnd + 0.000001, selectionEnd - selectionStart >= 0.5 - 0.000001 else { return nil }
        let rate = min(frameRate, 60)
        start = max(videoStart, videoStart + floor((selectionStart - videoStart) * rate + 0.000001) / rate)
        end = min(videoEnd, videoStart + ceil((selectionEnd - videoStart) * rate - 0.000001) / rate)
        duration = end - start
        let lastFrame = max(0, (floor(duration * rate + 0.000001) - 1) / rate)
        poster = max(0, min(((center - start) * rate).rounded() / rate, lastFrame))
    }
}
