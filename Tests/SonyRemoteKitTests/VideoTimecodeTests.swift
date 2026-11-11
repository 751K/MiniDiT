import Foundation
import Testing
@testable import SonyRemoteKit

@Suite struct VideoTimecodeTests {
    @Test func rationalRates() throws {
        #expect(try #require(VideoFrameRate("23.98p")).numerator == 24000)
        #expect(try #require(VideoFrameRate("59.94p")).denominator == 1001)
        #expect(VideoFrameRate("25p")?.frameDurationXML == "1/25s")
        #expect(VideoFrameRate("NaN") == nil)
        #expect(VideoFrameRate("0") == nil)
    }

    @Test func dropFrameBoundariesAndRoundTrip() throws {
        for fps in ["29.97p", "59.94p"] {
            let rate = try #require(VideoFrameRate(fps))
            let drop = rate.nominal / 15
            let before = try #require(VideoTimecode("00:00:59;\(rate.nominal - 1)", rate: rate))
            #expect(before.adding(frames: 1).text == String(format: "00:01:00;%02d", drop))
            let tenth = try #require(VideoTimecode("00:09:59;\(rate.nominal - 1)", rate: rate))
            #expect(tenth.adding(frames: 1).text == "00:10:00;00")
            #expect(VideoTimecode("00:01:00;00", rate: rate) == nil)
            for frame in stride(from: Int64(0), through: Int64(rate.nominal * 86400 - drop * 1296 - 1), by: 137) {
                let tc = try #require(VideoTimecode("00:00:00;00", rate: rate)).adding(frames: frame)
                #expect(VideoTimecode(tc.text, rate: rate)?.frameNumber == frame)
            }
        }
    }

    @Test func midnightAndSeek() throws {
        let rate = try #require(VideoFrameRate("25"))
        let start = try #require(VideoTimecode("23:59:59:24", rate: rate))
        #expect(start.adding(frames: 1).text == "00:00:00:00")
        #expect(start.adding(frames: -1).text == "23:59:59:23")
        let target = try #require(VideoTimecode("00:00:00:24", rate: rate))
        #expect(start.offset(to: target) == 1)
        #expect(VideoTimecode("24:00:00:00", rate: rate) == nil)
        #expect(VideoTimecode("00:00:00;00", rate: rate) == nil)
        let high = try #require(VideoFrameRate("100"))
        #expect(VideoTimecode("01:02:03:12", rate: rate)?.converted(to: high)?.text == "01:02:03:48")
        #expect(VideoTimecode("00:00:00:100", rate: high) == nil)
    }

    @Test func sonyHighFrameRateAndXMLOrder() throws {
        // 时间码表在帧率之前，50p 使用 25 fps 的 BCD + halfStep。
        let xml = #"<NonRealTimeMeta><LtcChangeTable tcFps="25" halfStep="true"><LtcChange frameCount="0" value="23801317"/></LtcChangeTable><Duration value="51"/><VideoFormat><VideoFrame formatFps="50p"/></VideoFormat></NonRealTimeMeta>"#
        let info = try #require(ClipInfo.parse(Data(xml.utf8)))
        #expect(info.timecode == "17:13:00:47")
        #expect(info.endTimecode == "17:13:01:47")
        #expect(info.startTimecode?.rate.nominal == 50)
        #expect(VideoTimecode.sony("AA090506", rate: try #require(VideoFrameRate("25")), halfStep: false) == nil)
    }

    @Test func sonyDropAndMissingTC() throws {
        let xml = #"<NonRealTimeMeta><LtcChangeTable tcFps="30"><LtcChange frameCount="0" value="61090506"/></LtcChangeTable><VideoFrame formatFps="29.97p"/></NonRealTimeMeta>"#
        let info = try #require(ClipInfo.parse(Data(xml.utf8)))
        #expect(info.timecode == "06:05:09;21")
        #expect(info.startTimecode?.format == "DF")
        let highXML = #"<NonRealTimeMeta><LtcChangeTable tcFps="30" halfStep="true"><LtcChange frameCount="0" value="61890506"/></LtcChangeTable><VideoFrame formatFps="59.94p"/></NonRealTimeMeta>"#
        #expect(ClipInfo.parse(Data(highXML.utf8))?.timecode == "06:05:09;43")
        #expect(ClipInfo.parse(Data("<NonRealTimeMeta/>".utf8))?.startTimecode == nil)
    }
}
