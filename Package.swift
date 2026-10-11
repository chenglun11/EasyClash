// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "EasyClash", platforms: [.macOS(.v13)],
    products: [.library(name: "EasyClashCore", targets: ["EasyClashCore"]),
               .executable(name: "EasyClash", targets: ["EasyClashApp"]),
               .executable(name: "EasyClashRecovery", targets: ["EasyClashRecovery"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "5.1.3")],
    targets: [.target(name: "EasyClashCore", dependencies: ["Yams"]),
              .executableTarget(name: "EasyClashApp", dependencies: ["EasyClashCore"]),
              .executableTarget(name: "EasyClashRecovery", dependencies: ["EasyClashCore"]),
              .executableTarget(name: "EasyClashTests", dependencies: ["EasyClashCore"], path: "Tests/EasyClashCoreTests")])
