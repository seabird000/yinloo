// swift-tools-version:6.0
import Foundation
import PackageDescription

// 本机转写用 sherpa-onnx（Apache-2.0）的 C 接口。动态库不进 Git：build.sh 第一次运行时从官方发布页下载、
// 核对校验码，解压到 .vendor/。只编译主程序（swift build --product E1Recorder）不需要它。
let sherpa = "sherpa-onnx-v2.0.1-osx-universal2-shared-no-tts-lib"
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "E1Recorder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "E1Recorder",
            dependencies: ["LocalASRCore"],
            path: "Sources/E1Recorder",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // 切段、分句、读 WAV、和识别子程序之间的消息格式。纯 Swift，主程序和子程序共用，测试直接测它
        .target(name: "LocalASRCore", path: "Sources/LocalASRCore"),
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        // 识别子程序：应用每转一条录音起一个，转完退出（崩了不带崩应用，内存也随进程还给系统）
        .executableTarget(
            name: "yinloo-asr",
            dependencies: ["LocalASRCore", "CSherpaOnnx"],
            path: "Sources/YinlooASR",
            linkerSettings: [.unsafeFlags([
                "-L", "\(here)/.vendor/\(sherpa)/lib",
                // 装好的应用：动态库在 Contents/Frameworks。下面两条是开发时直接从 .build 运行用的，build.sh 打包时删掉
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../.vendor/\(sherpa)/lib",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../.vendor/\(sherpa)/lib",
            ])]
        ),
        .testTarget(
            name: "E1RecorderTests",
            dependencies: ["E1Recorder", "LocalASRCore"],
            path: "Tests/E1RecorderTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
