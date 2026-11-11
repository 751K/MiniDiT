import Testing
@testable import MiniDiTCore

@Suite struct MediaFilterTests {
    @Test func markedIncludesBothKindsAndExcludesRejected() {
        var f = MediaFilter(); f.mark = .marked
        #expect(f.accepts(names: ["DSC1.ARW"], isVideo: false, rating: 3, hasShotMark: false))
        #expect(f.accepts(names: ["C001.MP4"], isVideo: true, rating: nil, hasShotMark: true))
        #expect(!f.accepts(names: ["DSC1.ARW"], isVideo: false, rating: -1, hasShotMark: false))
        #expect(!f.accepts(names: ["DSC1.ARW"], isVideo: false, rating: nil, hasShotMark: false))
    }
    @Test func filtersCombineAndSearchAcrossFileAndSource() {
        var f = MediaFilter(); f.query = "C001 主机"; f.mark = .shotMark
        #expect(f.accepts(names: ["C001.MP4", "主机 α7 V"], isVideo: true, rating: nil, hasShotMark: true))
        #expect(!f.accepts(names: ["C001.MP4", "副机"], isVideo: true, rating: nil, hasShotMark: true))
        #expect(!f.accepts(names: ["C001.MP4", "主机"], isVideo: true, rating: nil, hasShotMark: false))
    }
    @Test func starThresholdsDoNotSelectVideos() {
        var f = MediaFilter(); f.mark = .threeStars
        #expect(f.accepts(names: [], isVideo: false, rating: 5, hasShotMark: false))
        #expect(!f.accepts(names: [], isVideo: false, rating: 2, hasShotMark: false))
        #expect(!f.accepts(names: [], isVideo: true, rating: 5, hasShotMark: true))
        let thresholds: [(MediaFilter.Mark, Int)] = [
            (.rated, 1), (.twoStars, 2), (.threeStars, 3), (.fourStars, 4), (.fiveStars, 5),
        ]
        for (mark, threshold) in thresholds {
            f.mark = mark
            #expect(!f.accepts(names: [], isVideo: false, rating: threshold - 1, hasShotMark: false))
            #expect(f.accepts(names: [], isVideo: false, rating: threshold, hasShotMark: false))
        }
        f.mark = .rejected
        #expect(f.accepts(names: [], isVideo: false, rating: -1, hasShotMark: false))
    }
}
