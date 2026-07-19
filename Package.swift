// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DASHBOARD",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DASHBOARD", targets: ["DASHBOARD"])
    ],
    targets: [
        .executableTarget(
            name: "DASHBOARD",
            dependencies: [],
            path: "DASHBOARD",
            exclude: [
                "Assets.xcassets",
                "DASHBOARD.entitlements"
            ]
        )
    ]
)
