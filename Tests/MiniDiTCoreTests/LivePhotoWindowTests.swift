import Testing
import MiniDiTCore

@Suite struct LivePhotoWindowTests {
    @Test func beginningAndEndKeepChosenPosterWithinThreeSeconds() throws {
        let beginning = try #require(LivePhotoWindow(videoEnd: 10, center: 0.08, frameRate: 25))
        #expect(beginning.start == 0 && beginning.duration == 3 && beginning.poster == 0.08)
        let end = try #require(LivePhotoWindow(videoEnd: 10, center: 10, frameRate: 25))
        #expect(end.start == 7 && end.duration == 3)
        #expect(abs(end.poster - 2.96) < 0.0001 && end.sourcePoster < 10)
        let middle = try #require(LivePhotoWindow(videoEnd: 10, center: 5, frameRate: 30))
        #expect(middle.start == 3.5 && middle.poster == 1.5 && middle.end == 6.5)
    }
    @Test func oddFrameRateAlignsWindowSoTheChosenSourceFrameStaysTheCover() throws {
        let window = try #require(LivePhotoWindow(videoEnd: 5, center: 2, frameRate: 25))
        #expect(abs(window.start - 0.48) < 0.00001)
        #expect(abs(window.sourcePoster - 2) < 0.00001)
    }
    @Test func shortClipUsesActualDurationAndHandlesNonzeroTrackStart() throws {
        let short = try #require(LivePhotoWindow(videoEnd: 0.8, center: 0.4, frameRate: 30))
        #expect(short.duration == 0.8 && short.start == 0 && short.sourcePoster <= short.end)
        let offset = try #require(LivePhotoWindow(videoStart: 2, videoEnd: 7, center: 1, frameRate: 25))
        #expect(offset.start == 2 && offset.poster == 0 && offset.duration == 3)
    }
    @Test func rejectsInvalidOrUndersizedInputs() {
        #expect(LivePhotoWindow(videoEnd: 0.2, center: 0) == nil)
        #expect(LivePhotoWindow(videoEnd: .infinity, center: 0) == nil)
        #expect(LivePhotoWindow(videoEnd: 3, center: .nan) == nil)
        #expect(LivePhotoWindow(videoStart: -1, videoEnd: 3, center: 0) == nil)
        #expect(LivePhotoWindow(videoEnd: 3, center: 1, frameRate: 0) == nil)
    }
    @Test func fractionalFrameRatesKeepPosterAndSelectionInRange() throws {
        for rate in [23.976, 29.97, 59.94, 120] {
            for center in [0.0, 0.1, 1.5, 5, 9.99, 10, 20] {
                let window = try #require(LivePhotoWindow(videoEnd: 10, center: center, frameRate: rate))
                #expect(window.start >= 0 && window.end <= 10)
                #expect(window.poster >= 0 && window.poster < window.duration)
            }
        }
    }
    @Test func explicitInOutPreserveLongAndShortSelections() throws {
        let long = try #require(LivePhotoWindow(videoEnd: 12, selectionStart: 2, selectionEnd: 9, center: 4, frameRate: 25))
        #expect(long.start == 2 && long.end == 9 && long.duration == 7 && long.sourcePoster == 4)
        let short = try #require(LivePhotoWindow(videoEnd: 12, selectionStart: 4, selectionEnd: 5, center: 4.4, frameRate: 25))
        #expect(short.duration == 1 && abs(short.sourcePoster - 4.4) < 0.00001)
    }
    @Test func explicitSelectionClampsCoverAndKeepsFractionalFramesInsideSource() throws {
        for rate in [23.976, 25, 29.97, 60] {
            for center in [-10.0, 2.1, 3.4, 100] {
                let window = try #require(LivePhotoWindow(videoStart: 2, videoEnd: 6.13,
                    selectionStart: 2.11, selectionEnd: 6.13, center: center, frameRate: rate))
                #expect(window.start >= 2 && window.end <= 6.13)
                #expect(window.sourcePoster >= window.start && window.sourcePoster < window.end)
                #expect(abs((window.start - 2) * rate - ((window.start - 2) * rate).rounded()) < 0.00001)
                #expect(abs(window.poster * rate - (window.poster * rate).rounded()) < 0.00001)
            }
        }
    }
    @Test func explicitSelectionRejectsCrossedOutsideUndersizedAndNonfiniteRanges() {
        #expect(LivePhotoWindow(videoEnd: 10, selectionStart: 5, selectionEnd: 4, center: 4) == nil)
        #expect(LivePhotoWindow(videoEnd: 10, selectionStart: -1, selectionEnd: 4, center: 2) == nil)
        #expect(LivePhotoWindow(videoEnd: 10, selectionStart: 0, selectionEnd: 11, center: 2) == nil)
        #expect(LivePhotoWindow(videoEnd: 10, selectionStart: 0, selectionEnd: 0.2, center: 0.1) == nil)
        #expect(LivePhotoWindow(videoEnd: 10, selectionStart: .nan, selectionEnd: 2, center: 1) == nil)
        #expect(LivePhotoWindow(videoEnd: 10, selectionStart: 0, selectionEnd: .infinity, center: 1) == nil)
    }

}
