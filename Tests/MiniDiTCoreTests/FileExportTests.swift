import Foundation
import Testing
import MiniDiTCore
import SonyRemoteKit

@Suite struct FileExportTests {
    private func item(size: UInt64 = 4, sizeKnown: Bool = true) -> CameraContentItem {
        CameraContentItem(id: 1, storageID: 1, filename: "DSC00001.JPG", format: PTPObjectFormat.jpeg,
                          size: size, sizeKnown: sizeKnown, captureDate: nil, width: 0, height: 0)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func duplicateNamesReserveExistingSuffixesAndIgnoreCase() {
        #expect(FileExport.filenames(["A.JPG", "a.jpg", "A (2).JPG", "A.ARW", "A.ARW"])
                == ["A.JPG", "a (3).jpg", "A (2).JPG", "A.ARW", "A (2).ARW"])
        #expect(FileExport.filenames(["é.JPG", "e\u{301}.JPG"]).count == 2)
        #expect(FileExport.filenames(["é.JPG", "e\u{301}.JPG"])[1].contains("(2)"))
    }

    @Test func copiesOriginalWithoutMovingItAndUsesSuppliedDestinationName() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("original.JPG")
        let destination = dir.appendingPathComponent("Finder renamed (2).JPG")
        let data = Data([1, 2, 3, 4])
        try data.write(to: source)
        try await FileExport(item: item(), library: nil, localCopy: source).write(to: destination)
        #expect(try Data(contentsOf: source) == data)
        #expect(try Data(contentsOf: destination) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
    }

    @Test func existingFileIsNeverOverwritten() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("existing.JPG")
        try Data([9]).write(to: destination)
        await #expect(throws: (any Error).self) {
            try await FileExport(item: item(), library: nil).write(to: destination)
        }
        #expect(try Data(contentsOf: destination) == Data([9]))
    }

    @Test func failedSizeCheckRemovesTemporaryFileAndQueueContinues() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.JPG")
        let bad = dir.appendingPathComponent("bad.JPG")
        let good = dir.appendingPathComponent("good.JPG")
        try Data([1, 2, 3, 4]).write(to: source)
        let queue = FileExportQueue()
        await #expect(throws: (any Error).self) {
            try await queue.write(FileExport(item: item(size: 100), library: nil, localCopy: source), to: bad)
        }
        try await queue.write(FileExport(item: item(), library: nil, localCopy: source), to: good)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["source.JPG", "good.JPG"])
    }

    @Test func downloadsFromCardWhenCachedCopyDisappears() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dcim = dir.appendingPathComponent("DCIM/100MSDCF")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        let data = Data([5, 6, 7, 8])
        let source = dcim.appendingPathComponent("DSC00001.JPG")
        try data.write(to: source)
        let library = LocalCardLibrary(root: dir)
        let firstFolder = try #require(try await library.folders().first)
        let handle = try #require(try await library.handles(in: firstFolder).first)
        let file = try await library.item(handle)
        let destination = dir.appendingPathComponent("export.JPG")
        try await FileExport(item: file, library: library, localCopy: dir.appendingPathComponent("missing.JPG"))
            .write(to: destination)
        #expect(try Data(contentsOf: destination) == data)
        #expect(try Data(contentsOf: source) == data)
    }

    @Test func unknownSizeVideoIsNotMistakenForEmptyFile() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.MP4")
        let destination = dir.appendingPathComponent("video.MP4")
        try Data([1, 2, 3, 4]).write(to: source)
        try await FileExport(item: item(size: 0, sizeKnown: false), library: nil, localCopy: source).write(to: destination)
        #expect(try Data(contentsOf: destination).count == 4)
    }
}
