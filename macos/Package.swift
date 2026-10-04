// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Workholic",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Workholic", targets: ["Workholic"])
    ],
    targets: [
        .target(name: "WorkholicCore"),
        .executableTarget(
            name: "Workholic",
            dependencies: ["WorkholicCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "WorkholicTests", dependencies: ["WorkholicCore"]),
    ]
)
