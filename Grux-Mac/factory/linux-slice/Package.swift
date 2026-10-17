// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "grux-linux-slice",
    platforms: [
        .macOS(.v14),
    ],
    products: [],
    targets: [
        .target(
            name: "SwarmPlanSlice",
            path: "Sources"
        ),
    ]
)
