import Foundation
@main enum HermexEntry {
    @MainActor static func main() {
        #if DEBUG
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--protocol-smoke" {
            Task { @MainActor in
                do { try await ProtocolSmoke.run(address: CommandLine.arguments[2]); exit(0) }
                catch { fputs("Fixture smoke failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        #endif
        HermexApplication.main()
    }
}
