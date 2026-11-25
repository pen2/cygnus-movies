// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CygnusMovies",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CygnusMoviesCore", targets: ["CygnusMoviesCore"]),
        .executable(name: "CygnusMovies", targets: ["CygnusMovies"])
    ],
    targets: [
        .target(name: "CygnusMoviesCore", path: "Sources/CygnusMovies"),
        .executableTarget(name: "CygnusMovies", dependencies: ["CygnusMoviesCore"], path: "Sources/Free"),
        .testTarget(name: "MenuTests", path: "Tests/MenuTests")
    ]
)
