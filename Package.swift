// swift-tools-version: 6.0

import Foundation
import PackageDescription

let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? "/Library/Developer/CommandLineTools"
let developerFrameworksPath = "\(developerDirectory)/Library/Developer/Frameworks"
let developerLibrariesPath = "\(developerDirectory)/Library/Developer/usr/lib"

let package = Package(
    name: "CodexUsageMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexUsageMonitor", targets: ["CodexUsageMonitor"])
    ],
    targets: [
        .executableTarget(name: "CodexUsageMonitor"),
        .testTarget(
            name: "CodexUsageMonitorTests",
            dependencies: ["CodexUsageMonitor"],
            swiftSettings: [
                .unsafeFlags(["-F", developerFrameworksPath])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", developerFrameworksPath,
                    "-Xlinker", "-rpath",
                    "-Xlinker", developerFrameworksPath,
                    "-Xlinker", "-rpath",
                    "-Xlinker", developerLibrariesPath
                ])
            ]
        )
    ]
)
