import Foundation
import Testing
@testable import MiniDiTCore
import SonyRemoteKit

private func item(_ id: UInt32, _ name: String, _ fmt: UInt16, size: UInt64 = 100, date: String = "20261104T101500",
                  slot: UInt32 = 1) -> CameraContentItem {
    CameraContentItem(id: id, storageID: slot << 16 | 1, filename: name, format: fmt, size: size,
                      captureDate: HistoryIndex.parse(date), captureDateRaw: date, width: 0, height: 0)
}

@Suite struct ShotTests {
    @Test func rawAndJpegBecomeOneShot() {
        let shots = ShotBuilder.group([
            item(1, "DSC00002.ARW", PTPObjectFormat.sonyARW),
            item(2, "DSC00002.JPG", PTPObjectFormat.jpeg),
            item(3, "DSC00001.ARW", PTPObjectFormat.sonyARW),
            item(4, "C0001.MP4", PTPObjectFormat.mp4),
        ])
        #expect(shots.count == 3)
        #expect(shots[0].handles == [1, 2])
        #expect(shots[0].primary == 2)          // 缩略图用 JPEG
        #expect(shots[0].badge == "RAW+JPG")
        #expect(shots[1].badge == "RAW")
        #expect(shots[2].isVideo)
    }

    @Test func sameNameOnOtherSlotOrFarApartStaysSeparate() {
        let shots = ShotBuilder.group([
            item(1, "DSC00001.ARW", PTPObjectFormat.sonyARW, slot: 1),
            item(2, "DSC00001.JPG", PTPObjectFormat.jpeg, slot: 2),        // 另一张卡（同时记录 / 分开记录）
            item(3, "DSC00001.HIF", PTPObjectFormat.heif, date: "20250101T000000"),   // 计数器归零后的另一张
        ])
        #expect(shots.count == 3)
    }

    @Test func pairPolicyPicksFiles() {
        let shot = ShotBuilder.group([item(1, "A.ARW", PTPObjectFormat.sonyARW), item(2, "A.HIF", PTPObjectFormat.heif)])[0]
        let kinds: [UInt32: CameraContentItem.Kind] = [1: .raw, 2: .heif]
        #expect(ShotBuilder.files(of: shot, policy: .both, kindOf: { kinds[$0] }) == [1, 2])
        #expect(ShotBuilder.files(of: shot, policy: .rawOnly, kindOf: { kinds[$0] }) == [1])
        #expect(ShotBuilder.files(of: shot, policy: .jpegOnly, kindOf: { kinds[$0] }) == [2])
    }
}

@Suite struct SelectionTests {
    private func make() -> GridSelection<Int> {
        var s = GridSelection<Int>()
        s.setOrder(Array(0..<10))
        return s
    }

    @Test func plainClickSelectsOnlyOne() {
        var s = make()
        s.click(3); s.click(5)
        #expect(s.selected == [5])
    }

    @Test func commandClickToggles() {
        var s = make()
        s.click(1); s.click(4, .command); s.click(6, .command); s.click(4, .command)
        #expect(s.selected == [1, 6])
    }

    @Test func shiftClickSelectsRangeAndReplacesPreviousRange() {
        var s = make()
        s.click(2)
        s.click(6, .shift)
        #expect(s.selected == Set(2...6))
        s.click(4, .shift)             // 和访达一样：范围缩回到 2…4
        #expect(s.selected == Set(2...4))
        s.click(0, .shift)
        #expect(s.selected == Set(0...2))
    }

    @Test func shiftKeepsCommandSelections() {
        var s = make()
        s.click(8)
        s.click(2, .command)
        s.click(4, .shift)
        #expect(s.selected == Set([8]).union(2...4))
    }

    @Test func arrowKeysMoveAndExtend() {
        var s = make()
        s.move(.right, columns: 4)
        #expect(s.selected == [0])
        s.move(.down, columns: 4)
        #expect(s.selected == [4])
        s.move(.right, columns: 4, extend: true)
        s.move(.right, columns: 4, extend: true)
        #expect(s.selected == [4, 5, 6])
        s.move(.down, columns: 4)       // 最后一行不够：落到最后一个
        #expect(s.selected == [9])
    }

    @Test func boxSelectReplacesOrToggles() {
        var s = make()
        s.click(0)
        s.beginBox(additive: false)
        s.updateBox([3, 4])
        s.updateBox([3, 4, 5])
        s.endBox()
        #expect(s.selected == [3, 4, 5])
        s.beginBox(additive: true)
        s.updateBox([5, 6])
        s.endBox()
        #expect(s.selected == [3, 4, 6])
    }

    @Test func selectAllInvertAndHiddenItemsKept() {
        var s = make()
        s.click(1)
        s.setOrder([0, 2, 3])           // 1 被筛选隐藏了：选择保留
        #expect(s.contains(1))
        s.invert()
        #expect(s.selected == [0, 2, 3, 1])
        s.selectAll()
        #expect(s.selected == [0, 2, 3])
    }
}

@Suite struct HistoryTests {
    @Test func matchesAcrossSourcesWithinTimeWindow() {
        var h = HistoryIndex()
        // Wi-Fi 导入：有机身 ID，时间来自相机。
        h.insert(ImportRecord(filename: "DSC00001.ARW", size: 100, dateRaw: "20261104T101500", camera: "ILCE-7M5#1", path: "/a"))
        // 读卡器：没有机身 ID，时间是文件修改时间，差了 1 秒。
        #expect(h.contains(item(1, "DSC00001.ARW", PTPObjectFormat.sonyARW, date: "20261104T101501"), camera: nil))
        // 同一台相机。
        #expect(h.contains(item(1, "DSC00001.ARW", PTPObjectFormat.sonyARW), camera: "ILCE-7M5#1"))
    }

    @Test func otherBodyWithSameNameAndSizeIsNotImported() {
        var h = HistoryIndex()
        h.insert(ImportRecord(filename: "DSC00001.ARW", size: 100, dateRaw: "20261104T101500", camera: "ILCE-7M5#1", path: nil))
        #expect(!h.contains(item(1, "DSC00001.ARW", PTPObjectFormat.sonyARW), camera: "ILCE-7C2#9"))
        // 不同时间（计数器归零后的另一张）。
        #expect(!h.contains(item(1, "DSC00001.ARW", PTPObjectFormat.sonyARW, date: "20261105T101500"), camera: nil))
        // 大小不同。
        #expect(!h.contains(item(1, "DSC00001.ARW", PTPObjectFormat.sonyARW, size: 101), camera: nil))
    }

    @Test func reinsertUpdatesPath() {
        var h = HistoryIndex()
        h.insert(ImportRecord(filename: "A.JPG", size: 1, dateRaw: "20261104T101500", camera: nil, path: "/old"))
        h.insert(ImportRecord(filename: "A.JPG", size: 1, dateRaw: "20261104T101500", camera: "X#1", path: "/new"))
        #expect(h.records.count == 1)
        #expect(h.records[0].path == "/new")
        #expect(h.records[0].camera == "X#1")
    }

    @Test func migratesLegacyKeys() {
        let r = HistoryIndex.migrate(legacy: ["DSC1.JPG|42|20261104T101500": "/p", "bad": ""])
        #expect(r.count == 1)
        #expect(r[0].size == 42 && r[0].path == "/p" && r[0].camera == nil)
    }
}
