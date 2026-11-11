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
    public var version = 1
    public var groups: [Group]
    public init(groups: [Group]) { self.groups = groups }
}
