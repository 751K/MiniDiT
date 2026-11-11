import Foundation

/// Immutable Premiere import request. References working files without changing them.
public struct PremiereHandoff: Codable, Sendable, Equatable {
    public struct Mark: Codable, Sendable, Equatable {
        public var name: String
        public var seconds: Double
        public var duration: Double
        public init(name: String, seconds: Double, duration: Double) { self.name = name; self.seconds = seconds; self.duration = duration }
    }
    public struct Clip: Codable, Sendable, Equatable {
        public var path: String
        public var canonicalPath: String
        public var proxy: String?
        public var canonicalProxyPath: String?
        public var marks: [Mark]
        public init(url: URL, proxy: URL?, marks: [Mark] = []) {
            path = url.path; canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            self.proxy = proxy?.path; canonicalProxyPath = proxy?.resolvingSymlinksInPath().standardizedFileURL.path
            self.marks = marks
        }
    }
    public struct Group: Codable, Sendable, Equatable {
        public var binPath: [String]
        public var clips: [Clip]
        public init(binPath: [String], clips: [Clip]) { self.binPath = binPath; self.clips = clips }
    }
    /// 目标项目：与 MiniDiT 项目同名的 .prproj。已有就打开，没有就在这个位置新建。旧版本的请求没有这一项，发到当前项目。
    public struct Target: Codable, Sendable, Equatable {
        public var name: String
        public var path: String
        public init(name: String, path: String) { self.name = name; self.path = path }
    }
    public var version = 1
    public var project: Target?
    public var groups: [Group]
    public init(project: Target? = nil, groups: [Group]) { self.project = project; self.groups = groups }
}
