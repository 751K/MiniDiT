// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SonyRemoteKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SonyRemoteKit", targets: ["SonyRemoteKit"]),
        .executable(name: "fake-sony-camera", targets: ["fake-sony-camera"]),
    ],
    targets: [
        // 协议层：PTP/IP 传输 + 索尼 SDIO 命令，iOS 与 macOS 通用。
        // OpenSSL 3.5.9 + libssh2 1.11.1，由 Scripts/build-libssh2-xcframework.sh 从源码编译。
        .binaryTarget(name: "CLibssh2", path: "Vendor/CLibssh2.xcframework"),
        .target(name: "SonyRemoteKit", dependencies: ["CLibssh2"]),
        // 模拟相机：测试和本地联调用。
        .target(name: "FakeSonyCamera", dependencies: ["SonyRemoteKit"]),
        .executableTarget(name: "fake-sony-camera", dependencies: ["FakeSonyCamera"]),
        // SSH 访问身份验证端到端测试（Scripts/test-ssh-e2e.sh）。
        .executableTarget(name: "ssh-e2e", dependencies: ["SonyRemoteKit"]),
        .testTarget(name: "SonyRemoteKitTests", dependencies: ["SonyRemoteKit", "FakeSonyCamera"]),
    ]
)
