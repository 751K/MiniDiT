@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import MiniDiTCore
@preconcurrency import Photos
import SonyRemoteKit
import UniformTypeIdentifiers

/// Creates derived media only. The source, project records and verification baseline are never changed.
enum LivePhotoExporter {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case apple, motion
        var id: String { rawValue }
        var title: String { self == .apple ? "Apple Live Photo" : "Motion Photo" }
    }
    struct Result: Sendable {
        var url: URL, photo: URL, video: URL?
        var window: LivePhotoWindow
        var capturedAt: Date?
    }
    struct Media: Sendable {
        var start: Double, end: Double, frameRate: Double
        var duration: Double { end - start }
    }
    struct Failure: LocalizedError, Sendable {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    static func inspect(_ url: URL) async throws -> Media {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure(String(localized: "这个文件没有可导出的视频画面。")) }
        let (range, fps) = try await video.load(.timeRange, .nominalFrameRate)
        guard range.start.seconds.isFinite, range.duration.seconds.isFinite, range.duration.seconds >= 0.5 else { throw Failure(String(localized: "视频不足 0.5 秒，无法生成实况照片。")) }
        return .init(start: max(0, range.start.seconds), end: range.end.seconds, frameRate: min(60, fps > 0 ? Double(fps) : 30))
    }

    static func export(source: URL, center: Double, selection: LivePhotoWindow? = nil, format: Format, directory: URL, name: String, capturedAt: Date? = nil,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let fm = FileManager.default
        let media = try await inspect(source)
        let requested: LivePhotoWindow?
        if let selection {
            requested = LivePhotoWindow(videoStart: media.start, videoEnd: media.end,
                selectionStart: selection.start, selectionEnd: selection.end,
                center: selection.sourcePoster, frameRate: media.frameRate)
        } else {
            requested = LivePhotoWindow(videoStart: media.start, videoEnd: media.end, center: center, frameRate: media.frameRate)
        }
        guard let window = requested else { throw Failure(String(localized: "所选片段范围无效，请重新设置入点和出点。")) }
        try Task.checkCancellation()
        let staging = directory.appending(path: ".minidit-live-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let identifier = UUID().uuidString
        let movie = staging.appending(path: format == .apple ? "LivePhoto.MOV" : "motion.mp4")
        let image = staging.appending(path: "LivePhoto.JPG")
        var sourceDate = capturedAt
        if sourceDate == nil, let creation = try? await AVURLAsset(url: source).load(.creationDate) {
            sourceDate = try? await creation.load(.dateValue)
        }
        let date = sourceDate?.addingTimeInterval(window.sourcePoster)
        let pipeline = try await Pipeline(source: source, movie: movie, window: window, frameRate: media.frameRate, identifier: format == .apple ? identifier : nil, capturedAt: date)
        try await withTaskCancellationHandler { try await pipeline.run(progress: progress) } onCancel: { pipeline.cancel() }
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let generated = try await generator.image(at: CMTime(seconds: window.poster, preferredTimescale: 60000))
        try writeJPEG(generated.image, to: image, identifier: format == .apple ? identifier : nil, capturedAt: date)
        progress(0.9)
        if format == .apple { try await validate(photo: image, video: movie) }
        try Task.checkCancellation()
        let stem = String(NameTemplate.sanitize(name.isEmpty ? source.deletingPathExtension().lastPathComponent : name).prefix(64))
        let position = String(format: "%06.2f", window.sourcePoster).replacingOccurrences(of: ".", with: "-")
        if format == .apple {
            let output = try publish(staging, into: directory, name: stem + "-" + position + "-LivePhoto", extension: "")
            progress(1)
            return .init(url: output, photo: output.appending(path: image.lastPathComponent), video: output.appending(path: movie.lastPathComponent), window: window, capturedAt: date)
        } else {
            let motion = staging.appending(path: "motionMP.JPG")
            try writeMotionPhoto(photo: image, video: movie, poster: window.poster, to: motion)
            try Task.checkCancellation()
            let output = try publish(motion, into: directory, name: stem + "-" + position + "MP", extension: "JPG")
            progress(1)
            return .init(url: output, photo: output, video: nil, window: window, capturedAt: date)
        }
    }

    private static func publish(_ file: URL, into directory: URL, name: String, extension suffix: String) throws -> URL {
        for index in 0..<10000 {
            try Task.checkCancellation()
            let stem = name + (index == 0 ? "" : "-\(index + 1)")
            let target = directory.appending(path: stem + (suffix.isEmpty ? "" : "." + suffix))
            do { try FileManager.default.moveItem(at: file, to: target); return target }
            catch CocoaError.fileWriteFileExists { continue }
        }
        throw Failure(String(localized: "此位置存在太多同名文件，请选择其他文件夹。"))
    }
    private static func writeJPEG(_ image: CGImage, to url: URL, identifier: String?, capturedAt: Date?) throws {
        guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure(String(localized: "无法创建实况照片封面。")) }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let identifier { properties[kCGImagePropertyMakerAppleDictionary] = ["17": identifier] }
        if let capturedAt {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let offset = DateFormatter(); offset.locale = Locale(identifier: "en_US_POSIX"); offset.dateFormat = "XXX"
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: capturedAt), kCGImagePropertyExifOffsetTimeOriginal: offset.string(from: capturedAt)]
        }
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw Failure(String(localized: "实况照片封面保存失败。")) }
    }
    /// Motion Photo 1.0: XMP container directory followed by tightly packed JPEG and MP4 resources.
    static func writeMotionPhoto(photo: URL, video: URL, poster: Double, to output: URL) throws {
        let jpeg = try Data(contentsOf: photo)
        guard jpeg.starts(with: [0xff, 0xd8]), let size = (try video.resourceValues(forKeys: [.fileSizeKey])).fileSize, size > 0 else { throw Failure(String(localized: "实况照片的图片或视频不完整。")) }
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:Camera="http://ns.google.com/photos/1.0/camera/" xmlns:Container="http://ns.google.com/photos/1.0/container/" xmlns:Item="http://ns.google.com/photos/1.0/container/item/" Camera:MotionPhoto="1" Camera:MotionPhotoVersion="1" Camera:MotionPhotoPresentationTimestampUs="\(Int64((poster * 1_000_000).rounded()))"><Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Padding="0"/></rdf:li><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="\(size)"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        var packet = Data("http://ns.adobe.com/xap/1.0/\0".utf8); packet.append(Data(xmp.utf8))
        let count = packet.count + 2
        guard count < 65536 else { throw Failure(String(localized: "实况照片元数据超出格式限制。")) }
        var header = Data([0xff, 0xd8, 0xff, 0xe1, UInt8(count >> 8), UInt8(count & 255)])
        header.append(packet); header.append(jpeg.dropFirst(2))
        try header.write(to: output, options: .withoutOverwriting)
        let destination = try FileHandle(forWritingTo: output), movie = try FileHandle(forReadingFrom: video)
        defer { try? destination.close(); try? movie.close() }
        try destination.seekToEnd()
        while let data = try movie.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); try destination.write(contentsOf: data) }
    }

    private final class Pipeline: @unchecked Sendable {
        let reader: AVAssetReader, writer: AVAssetWriter
        let videoOutput: AVAssetReaderVideoCompositionOutput, videoInput: AVAssetWriterInput
        let audioOutput: AVAssetReaderTrackOutput?, audioInput: AVAssetWriterInput?
        let duration: Double
        init(source: URL, movie: URL, window: LivePhotoWindow, frameRate: Double, identifier: String?, capturedAt: Date?) async throws {
            duration = window.duration
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure(String(localized: "视频轨道无法读取。")) }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let composition = AVMutableComposition()
            guard let composed = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Failure(String(localized: "无法创建视频轨道。")) }
            let range = CMTimeRange(start: CMTime(seconds: window.start, preferredTimescale: 60000), duration: CMTime(seconds: window.duration, preferredTimescale: 60000))
            try composed.insertTimeRange(range, of: track, at: .zero)
            var composedAudio: AVMutableCompositionTrack?
            if let originalAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let available = try await originalAudio.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
                if intersection.duration.seconds > 0, let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try audio.insertTimeRange(intersection, of: originalAudio, at: CMTimeSubtract(intersection.start, range.start)); composedAudio = audio
                }
            }
            let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
            guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { throw Failure(String(localized: "无法确定视频尺寸。")) }
            let scale = min(1, 3840 / max(bounds.width, bounds.height))
            let width = max(2, Int(bounds.width * scale) / 2 * 2), height = max(2, Int(bounds.height * scale) / 2 * 2)
            let rate = VideoFrameRate(String(format: "%.3f", frameRate)) ?? VideoFrameRate("30")!
            let frame = CMTime(value: rate.denominator, timescale: CMTimeScale(rate.numerator))
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = CGSize(width: width, height: height); videoComposition.frameDuration = frame
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: composed)
            layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)).concatenating(CGAffineTransform(scaleX: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)), at: .zero)
            let instruction = AVMutableVideoCompositionInstruction(); instruction.timeRange = CMTimeRange(start: .zero, duration: range.duration); instruction.layerInstructions = [layer]
            videoComposition.instructions = [instruction]
            reader = try AVAssetReader(asset: composition)
            videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [composed], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            videoOutput.videoComposition = videoComposition; videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else { throw Failure(String(localized: "系统无法解码这个视频。")) }; reader.add(videoOutput)
            writer = try AVAssetWriter(outputURL: movie, fileType: identifier == nil ? .mp4 : .mov)
            writer.shouldOptimizeForNetworkUse = true
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(40_000_000, max(6_000_000, width * height * 5)), AVVideoExpectedSourceFrameRateKey: rate.value, AVVideoMaxKeyFrameIntervalKey: max(1, rate.nominal), AVVideoAllowFrameReorderingKey: false]])
            guard writer.canAdd(videoInput) else { throw Failure(String(localized: "系统无法编码实况照片视频。")) }; writer.add(videoInput)
            if let composedAudio {
                let output = AVAssetReaderTrackOutput(track: composedAudio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]); output.alwaysCopiesSampleData = false
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000])
                guard reader.canAdd(output), writer.canAdd(input) else { throw Failure(String(localized: "系统无法处理这个视频的音轨。")) }
                reader.add(output); writer.add(input); audioOutput = output; audioInput = input
            } else { audioOutput = nil; audioInput = nil }
            var metadata: [AVMetadataItem] = []
            if let capturedAt {
                let creation = AVMutableMetadataItem(); creation.identifier = .quickTimeMetadataCreationDate
                creation.value = ISO8601DateFormatter().string(from: capturedAt) as NSString; creation.dataType = kCMMetadataBaseDataType_UTF8 as String; metadata.append(creation)
            }
            if let identifier {
                let item = AVMutableMetadataItem(); item.identifier = .quickTimeMetadataContentIdentifier; item.value = identifier as NSString; item.dataType = kCMMetadataBaseDataType_UTF8 as String; metadata.append(item)
                var description: CMFormatDescription?
                let specification: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time", kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8]
                let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description)
                guard status == noErr, let description else { throw Failure(String(localized: "无法创建实况照片的封面时间标记。")) }
                let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
                guard writer.canAdd(input) else { throw Failure(String(localized: "系统不支持实况照片时间标记。")) }; writer.add(input)
                metadataInput = input; metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
            } else { metadataInput = nil; metadataAdaptor = nil }
            writer.metadata = metadata
            poster = window.poster; frameDuration = frame
        }
        let metadataInput: AVAssetWriterInput?, metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        let poster: Double, frameDuration: CMTime
        func cancel() { reader.cancelReading(); writer.cancelWriting() }
        func run(progress: @escaping @Sendable (Double) -> Void) async throws {
            do {
                try Task.checkCancellation()
                guard writer.startWriting() else { throw writer.error ?? Failure(String(localized: "无法开始写入视频。")) }
                writer.startSession(atSourceTime: .zero)
                guard reader.startReading() else { throw reader.error ?? Failure(String(localized: "无法开始解码视频。")) }
                if let adaptor = metadataAdaptor, let input = metadataInput {
                    let marker = AVMutableMetadataItem(); marker.keySpace = .quickTimeMetadata; marker.key = "com.apple.quicktime.still-image-time" as NSString
                    marker.value = NSNumber(value: Int8(0)); marker.dataType = kCMMetadataBaseDataType_SInt8 as String
                    let group = AVTimedMetadataGroup(items: [marker], timeRange: CMTimeRange(start: CMTime(seconds: poster, preferredTimescale: 60000), duration: frameDuration))
                    guard adaptor.append(group) else { throw writer.error ?? Failure(String(localized: "实况照片封面时间写入失败。")) }; input.markAsFinished()
                }
                try await withThrowingTaskGroup(of: Void.self) { tasks in
                    tasks.addTask { try await self.pumpVideo(progress: progress) }
                    if audioOutput != nil { tasks.addTask { try await self.pumpAudio() } }
                    for try await _ in tasks {}
                }
                try Task.checkCancellation()
                guard reader.status == .completed else { throw reader.error ?? Failure(String(localized: "视频解码未完成。")) }
                writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60000))
                await writer.finishWriting()
                try Task.checkCancellation()
                guard writer.status == .completed else { throw writer.error ?? Failure(String(localized: "视频写入未完成。")) }
            } catch { cancel(); if Task.isCancelled { throw CancellationError() }; throw error }
        }
        private func pumpVideo(progress: @escaping @Sendable (Double) -> Void) async throws {
            defer { videoInput.markAsFinished() }
            while true {
                try Task.checkCancellation()
                if writer.status == .failed { throw writer.error ?? Failure(String(localized: "视频编码失败。")) }
                if !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)); continue }
                guard let sample = videoOutput.copyNextSampleBuffer() else { break }
                guard videoInput.append(sample) else { throw writer.error ?? Failure(String(localized: "视频帧写入失败。")) }
                progress(min(0.85, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration * 0.85))
            }
        }
        private func pumpAudio() async throws {
            guard let output = audioOutput, let input = audioInput else { return }
            defer { input.markAsFinished() }
            while true {
                try Task.checkCancellation()
                if writer.status == .failed { throw writer.error ?? Failure(String(localized: "音频编码失败。")) }
                if !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)); continue }
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard input.append(sample) else { throw writer.error ?? Failure(String(localized: "音频写入失败。")) }
            }
        }
    }

    static func validate(photo: URL, video: URL) async throws {
        let request = LivePhotoValidation()
        try await withTaskCancellationHandler {
            try await request.check(photo: photo, video: video)
        } onCancel: { request.cancel() }
    }
    private final class LivePhotoValidation: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?, id: PHLivePhotoRequestID?, stopped = false
        func check(photo: URL, video: URL) async throws {
            let timeout = Task { try? await Task.sleep(for: .seconds(30)); if !Task.isCancelled { self.stop(Failure(String(localized: "系统未能确认实况照片，请稍后重试。"))) } }
            defer { timeout.cancel() }
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); self.continuation = continuation; let wasStopped = self.stopped; lock.unlock()
                if wasStopped { finish(CancellationError()); return }
                let identifier = PHLivePhoto.request(withResourceFileURLs: [photo, video], placeholderImage: nil, targetSize: CGSize(width: 320, height: 320), contentMode: .aspectFit) { livePhoto, info in
                    if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                    self.finish(livePhoto != nil ? nil : (info[PHLivePhotoInfoErrorKey] as? Error) ?? Failure(String(localized: "导出文件未被系统识别为实况照片。")))
                }
                lock.lock(); id = identifier; let cancel = self.stopped; lock.unlock()
                if cancel { PHLivePhoto.cancelRequest(withRequestID: identifier) }
            }
        }
        func finish(_ error: Error?) {
            lock.lock(); let callback = continuation; continuation = nil; lock.unlock()
            guard let callback else { return }
            if let error { callback.resume(throwing: error) } else { callback.resume() }
        }
        func cancel() { stop(CancellationError()) }
        private func stop(_ error: Error) {
            lock.lock(); stopped = true; let identifier = id; lock.unlock()
            if let identifier { PHLivePhoto.cancelRequest(withRequestID: identifier) }; finish(error)
        }
    }
}
