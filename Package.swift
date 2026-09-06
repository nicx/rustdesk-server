// swift-tools-version:5.9
import PackageDescription

// Ein Executable-Target, zwei Betriebsarten (siehe main.swift): Menüleisten-App
// oder Supervisor für einen der beiden RustDesk-Serverprozesse. Bewusst ohne
// jede Paketabhängigkeit — die fertige App soll auf jedem Mac ohne Vorbereitung
// laufen.
let package = Package(
    name: "RustDeskServer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "RustDeskServer", path: "Sources/RustDeskServer")
    ]
)
