// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PromiseLedger",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PromiseLedger", targets: ["PromiseLedger"]),
        .executable(name: "LedgerCheck", targets: ["LedgerCheck"]),
        .executable(name: "LedgerTests", targets: ["LedgerTests"]),
        .executable(name: "ImportTests", targets: ["ImportTests"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "LedgerCore", dependencies: ["CSQLite"]),
        .target(name: "LedgerMac", dependencies: ["LedgerCore"]),
        .executableTarget(name: "PromiseLedger", dependencies: ["LedgerCore", "LedgerMac"]),
        .executableTarget(name: "LedgerCheck", dependencies: ["LedgerCore", "LedgerMac"]),
        .executableTarget(name: "LedgerTests", dependencies: ["LedgerCore", "CSQLite"], path: "Tests/LedgerCoreTests"),
        .executableTarget(name: "ImportTests", dependencies: ["LedgerMac"], path: "Tests/ImportTests")
    ]
)
