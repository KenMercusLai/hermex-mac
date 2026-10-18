// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Link the original MIT-licensed portable contract and networking directly.
let upstreamModels = ["JSONValue", "Session", "ChatMessage", "MessageAttachment", "AttachmentAudioDetection", "ToolCall", "ContextWindowSnapshot", "ServerInfo", "ServerCatalog", "Workspace", "UploadResponse", "Goal", "Approval", "Clarification", "Skills", "Memory", "Kanban", "Cron", "CronRunHistory", "CronRecentCompletion", "TurnFileChangeSummary", "GitWorkspace", "ANSIEscapes"]
let upstreamNetworking = ["APIClient", "APIError", "CustomHeader", "Endpoints", "MultipartFormData", "APIClient+Sessions", "APIClient+Chat", "APIClient+Upload", "APIClient+Workspace", "APIClient+ServerPanels", "APIClient+Skills", "APIClient+ProviderQuota", "APIClient+Cron", "APIClient+SessionExport"]
let sources = upstreamModels.map { "HermesMobile/Models/\($0).swift" } +
    upstreamNetworking.map { "HermesMobile/Networking/\($0).swift" } + [
        "HermesMobile/Features/Insights/InsightsModels.swift",
        "HermesMobile/Features/Insights/UsageChartData.swift",
        "HermesMobile/Features/Chat/SlashCommandRanker.swift", "macOS/Sources"
    ]

// macOS/Sources includes native message presentation/downloads; documentation
// and Python wire fixtures stay outside the shipped executable target.
// An explicit source allowlist keeps all iOS resources/targets intact without
// invoking Xcode-only asset or string catalog compilers. Exclude every unrelated
// subtree, including new upstream files, instead of letting SPM infer resources.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func excluded(_ relative: String = "") -> [String] {
    let directory = root.appendingPathComponent(relative)
    return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted().flatMap { name -> [String] in
        if name == "Package.swift" || name == ".git" || name == ".build" || name == ".swiftpm" { return [] }
        let path = relative.isEmpty ? name : relative + "/" + name
        if sources.contains(path) { return [] }
        if sources.contains(where: { $0.hasPrefix(path + "/") }) { return excluded(path) }
        return [path]
    }
}
let package = Package(
    name: "HermexMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Hermex", targets: ["HermexMac"])],
    targets: [
        .executableTarget(name: "HermexMac", path: ".", exclude: excluded(), sources: sources,
                          swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals"),
                                          .unsafeFlags(["-F", root.appendingPathComponent(".build/sparkle").path])],
                          linkerSettings: [.unsafeFlags(["-F", root.appendingPathComponent(".build/sparkle").path,
                                                         "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "HermexMacTests", dependencies: ["HermexMac"], path: "macOS/Tests",
                    exclude: ["protocol_fixture.py", "media_fixture.py", "run_smoke.py", "test_updates.py", "update_install_smoke.py", "__pycache__"],
                    swiftSettings: [.unsafeFlags(["-F", root.appendingPathComponent(".build/sparkle").path])])
    ],
    swiftLanguageModes: [.v5]
)
