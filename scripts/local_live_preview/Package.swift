// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmiLocalLive",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ParakeetWorker", targets: ["ParakeetWorker"])],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b"
        )
    ],
    targets: [
        .executableTarget(
            name: "ParakeetWorker",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: ".",
            sources: ["ParakeetWorker.swift"]
        )
    ]
)
