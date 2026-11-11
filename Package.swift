// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIBalanceBoard",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AIBalanceBoard", targets: ["AIBalanceBoard"])],
    targets: [
        .target(name: "BalanceCore"),
        .executableTarget(name: "AIBalanceBoard", dependencies: ["BalanceCore"]),
        .executableTarget(name: "BalanceChecks", dependencies: ["BalanceCore"], path: "Tests/BalanceCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
