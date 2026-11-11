import Foundation

/// 剪映专业版草稿：导入的视频只登记在草稿的素材区，时间线留空，由用户自己挑选。
///
/// 剪映 6 起把草稿文件存成密文，但仍接受新建的明文草稿：它会发现草稿文件夹里新出现的子文件夹，
/// 打开时自行转换格式并登记到 `root_meta_info.json`。还没在剪映里打开过的草稿仍是明文，可以往素材区追加；
/// 打开过的草稿 MiniDiT 读不懂也不应改写，只报告给用户。字段结构参照 pyJianYingDraft（Apache-2.0）整理的草稿格式，
/// 在剪映专业版 11.7（macOS）上验证过：素材区显示片段，时间线为空。
public enum JianyingDraft {
    public struct Clip: Codable, Sendable, Equatable {
        public var path: String
        /// 秒。
        public var duration: Double
        public var width: Int
        public var height: Int
        public var fps: Double?
        public init(path: String, duration: Double, width: Int, height: Int, fps: Double? = nil) {
            self.path = path; self.duration = duration; self.width = width; self.height = height; self.fps = fps
        }
    }

    /// 冻结在导入记录里的交接内容：草稿名和片段，重试时原样使用。
    public struct Handoff: Codable, Sendable, Equatable {
        public var name: String
        public var clips: [Clip]
        public init(name: String, clips: [Clip]) { self.name = name; self.clips = clips }
    }

    public struct Failure: LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static let bundleID = "com.lemon.lvpro"

    /// 剪映默认的草稿位置。用户在剪映里改过草稿位置时不在这里。
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Movies/JianyingPro/User Data/Projects/com.lveditor.draft", directoryHint: .isDirectory)
    }

    /// 交给剪映的结果。
    public enum Outcome: Sendable, Equatable {
        /// 新建了草稿。
        case created
        /// 加入了已有草稿：新增几个，几个已经在素材区。
        case added(new: Int, existing: Int)
        /// 同名草稿已在剪映中打开过，文件已被剪映加密，不能再改。
        case locked
    }

    /// 按名字找草稿：没有就新建；有且剪映还没打开过（文件仍是明文）就把片段加进素材区；已经打开过就不动它。
    @discardableResult
    public static func deliver(_ handoff: Handoff, id: UUID, in root: URL, now: Date = Date()) throws -> (folder: URL, outcome: Outcome) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure(message: "未找到剪映的草稿文件夹，请先打开一次剪映专业版。")
        }
        guard !handoff.clips.isEmpty else { throw Failure(message: "没有可以加入剪映的视频。") }
        let name = draftName(handoff.name)
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: folder.path) else {
            try create(handoff, id: id, name: name, in: root, now: now)
            return (folder, .created)
        }
        let metaURL = folder.appending(path: "draft_meta_info.json")
        guard let data = try? Data(contentsOf: metaURL),
              var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var groups = meta["draft_materials"] as? [[String: Any]] else { return (folder, .locked) }
        let index = groups.firstIndex { $0["type"] as? Int == 0 }
        var videos = index.flatMap { groups[$0]["value"] as? [[String: Any]] } ?? []
        let known = Set(videos.compactMap { $0["file_Path"] as? String })
        let fresh = handoff.clips.filter { !known.contains($0.path) }
        if !fresh.isEmpty {
            videos += fresh.map { video($0, now: now) }
            if let index { groups[index]["value"] = videos } else { groups.insert(["type": 0, "value": videos], at: 0) }
            meta["draft_materials"] = groups
            meta["tm_draft_modified"] = micros(now.timeIntervalSince1970)
            try write(meta, to: metaURL)
        }
        return (folder, .added(new: fresh.count, existing: handoff.clips.count - fresh.count))
    }

    /// 新建草稿。先写到隐藏的临时文件夹，写完再改名，剪映不会看到写了一半的草稿；同名文件夹已存在时改名失败，不覆盖。
    static func create(_ handoff: Handoff, id: UUID, name: String, in root: URL, now: Date) throws {
        let fm = FileManager.default
        let staging = root.appending(path: ".minidit-" + id.uuidString, directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            try write(info(handoff, now: now), to: staging.appending(path: "draft_info.json"))
            try write(meta(handoff, id: id, name: name, folder: folder, root: root, now: now), to: staging.appending(path: "draft_meta_info.json"))
            try fm.moveItem(at: staging, to: folder)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// 草稿名就是文件夹名：去掉路径分隔符和开头的点。
    static func draftName(_ name: String) -> String {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        return base.isEmpty ? "MiniDiT" : base
    }

    // MARK: 草稿文件

    private static func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private static func micros(_ seconds: Double) -> Int { Int((seconds * 1_000_000).rounded()) }

    /// 平台信息：剪映据此判断草稿来源。
    private static var platform: [String: Any] { ["app_id": 3704, "app_source": "lv", "app_version": "11.7.0", "os": "mac"] }

    /// draft_info.json：画布按第一个片段，时间线和已用素材都为空。
    static func info(_ handoff: Handoff, now: Date) -> [String: Any] {
        let first = handoff.clips.first
        let width = (first?.width ?? 0) > 0 ? first!.width : 1920
        let height = (first?.height ?? 0) > 0 ? first!.height : 1080
        let materialKeys = ["ai_translates", "audio_balances", "audio_effects", "audio_fades", "audio_track_indexes", "audios",
                            "beats", "canvases", "chromas", "color_curves", "digital_humans", "drafts", "effects", "flowers",
                            "green_screens", "handwrites", "hsl", "images", "log_color_wheels", "loudnesses", "manual_deformations",
                            "masks", "material_animations", "material_colors", "multi_language_refs", "placeholders", "plugin_effects",
                            "primary_color_wheels", "realtime_denoises", "shapes", "smart_crops", "smart_relights",
                            "sound_channel_mappings", "speeds", "stickers", "tail_leaders", "text_templates", "texts", "time_marks",
                            "transitions", "video_effects", "video_trackings", "videos", "vocal_beautifys", "vocal_separations"]
        return [
            "canvas_config": ["height": height, "ratio": "original", "width": width],
            "color_space": 0,
            "config": [
                "adjust_max_index": 1, "attachment_info": [Any](), "combination_max_index": 1, "export_range": NSNull(),
                "extract_audio_last_index": 1, "lyrics_recognition_id": "", "lyrics_sync": true, "lyrics_taskinfo": [Any](),
                "maintrack_adsorb": true, "material_save_mode": 0, "multi_language_current": "none", "multi_language_list": [Any](),
                "multi_language_main": "none", "multi_language_mode": "none", "original_sound_last_index": 1,
                "record_audio_last_index": 1, "sticker_max_index": 1, "subtitle_keywords_config": NSNull(),
                "subtitle_recognition_id": "", "subtitle_sync": true, "subtitle_taskinfo": [Any](), "system_font_list": [Any](),
                "video_mute": false, "zoom_info_params": NSNull(),
            ],
            "cover": NSNull(),
            "create_time": Int(now.timeIntervalSince1970),
            "duration": 0,
            "extra_info": NSNull(),
            "fps": first?.fps.flatMap { $0 > 0 ? $0 : nil } ?? 30.0,
            "free_render_index_mode_on": false,
            "group_container": NSNull(),
            "id": UUID().uuidString,
            "keyframe_graph_list": [Any](),
            "keyframes": ["adjusts": [Any](), "audios": [Any](), "effects": [Any](), "filters": [Any](), "handwrites": [Any](),
                          "stickers": [Any](), "texts": [Any](), "videos": [Any]()],
            "last_modified_platform": platform,
            "platform": platform,
            "materials": Dictionary(uniqueKeysWithValues: materialKeys.map { ($0, [Any]()) }),
            "mutable_config": NSNull(),
            "name": "",
            "new_version": "110.0.0",
            "relationships": [Any](),
            "render_index_track_mode_on": false,
            "retouch_cover": NSNull(),
            "source": "default",
            "static_cover_image_path": "",
            "time_marks": NSNull(),
            "tracks": [Any](),
            "update_time": Int(now.timeIntervalSince1970),
            "version": 360000,
        ]
    }

    /// 素材区里的一条视频。
    static func video(_ clip: Clip, now: Date) -> [String: Any] {
        let seconds = Int(now.timeIntervalSince1970)
        return [
            "create_time": seconds, "duration": micros(clip.duration),
            "extra_info": URL(filePath: clip.path).lastPathComponent, "file_Path": clip.path,
            "height": clip.height, "id": UUID().uuidString.lowercased(),
            "import_time": seconds, "import_time_ms": micros(now.timeIntervalSince1970), "item_source": 1, "md5": "", "metetype": "video",
            "roughcut_time_range": ["duration": -1, "start": -1], "sub_time_range": ["duration": -1, "start": -1],
            "type": 0, "width": clip.width,
        ]
    }

    /// draft_meta_info.json：素材区的内容在 draft_materials 的 type 0 里，每个片段一条。
    static func meta(_ handoff: Handoff, id: UUID, name: String, folder: URL, root: URL, now: Date) -> [String: Any] {
        let microsNow = micros(now.timeIntervalSince1970)
        let videos = handoff.clips.map { video($0, now: now) }
        return [
            "cloud_package_completed_time": "", "draft_cloud_capcut_purchase_info": "", "draft_cloud_last_action_download": false,
            "draft_cloud_materials": [Any](), "draft_cloud_purchase_info": "", "draft_cloud_template_id": "",
            "draft_cloud_tutorial_info": "", "draft_cloud_videocut_purchase_info": "", "draft_cover": "",
            "draft_deeplink_url": "",
            "draft_enterprise_info": ["draft_enterprise_extra": "", "draft_enterprise_id": "", "draft_enterprise_name": "",
                                      "enterprise_material": [Any]()],
            "draft_fold_path": folder.path, "draft_id": id.uuidString, "draft_is_ai_packaging_used": false,
            "draft_is_ai_shorts": false, "draft_is_ai_translate": false, "draft_is_article_video_draft": false,
            "draft_is_from_deeplink": "false", "draft_is_invisible": false,
            "draft_materials": [0, 1, 2, 3, 6, 7, 8].map { type in ["type": type, "value": type == 0 ? videos : [[String: Any]]()] },
            "draft_materials_copied_info": [Any](), "draft_name": name, "draft_new_version": "",
            "draft_removable_storage_device": "", "draft_root_path": root.path, "draft_segment_extra_info": [Any](),
            "draft_type": "", "tm_draft_cloud_completed": "", "tm_draft_cloud_modified": 0,
            "tm_draft_create": microsNow, "tm_draft_modified": microsNow, "tm_draft_removed": 0, "tm_duration": 0,
        ]
    }
}
