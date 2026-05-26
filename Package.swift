// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenAIEgressStatus",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenAIEgressCore", targets: ["OpenAIEgressCore"]),
        .executable(name: "OpenAIEgressStatus", targets: ["OpenAIEgressStatus"]),
        .executable(name: "OpenAIEgressCoreCheck", targets: ["OpenAIEgressCoreCheck"]),
    ],
    targets: [
        .target(name: "OpenAIEgressCore"),
        .executableTarget(
            name: "OpenAIEgressStatus",
            dependencies: ["OpenAIEgressCore"]
        ),
        .executableTarget(
            name: "OpenAIEgressCoreCheck",
            dependencies: ["OpenAIEgressCore"],
            path: "Checks/OpenAIEgressCoreCheck"
        ),
    ]
)
