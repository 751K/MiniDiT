import Foundation

/// 一天的拍摄（按相机里的拍摄日期分组，不受 Mac 时区影响）。
struct ShootingDay: Identifiable, Hashable {
    let id: String          // yyyyMMdd，没有日期的是 "unknown"
    let title: String
    var shots: [UInt32]
    var importedCount: Int
    var newCount: Int { shots.count - importedCount }
    /// 没导入过的照片 / 片段数。侧栏 tooltip 直接用，免得每次渲染都扫一遍。
    var newPhotos = 0
    var newVideos = 0
    /// 内容里的片段总数；照片数 = shots.count - videos。
    var videos = 0
    var photos: Int { shots.count - videos }
    /// 按时间间隔分出的场次（新的在前）；没有分组或只有一场时只有一个。
    var scenes: [ShootingScene] = []
    /// 只显示了这一天的部分场次（侧栏点的是场次，不是日期）。
    var partial = false
}

/// 一天里的一场：相邻两张隔得比「场次间隔」久，就分成两场。
struct ShootingScene: Identifiable, Hashable {
    let id: String          // 「yyyyMMdd-场次号」
    /// 这一天里的第几场（从早到晚，从 1 开始）。
    let number: Int
    /// 「14:05–16:30」，按相机记录的时间（不换算时区）。
    let timeRange: String
    var shots: [UInt32]
    var importedCount: Int
    var newCount: Int { shots.count - importedCount }
    var newPhotos = 0
    var newVideos = 0
    var videos = 0
    var photos: Int { shots.count - videos }
}
