import Foundation
@main enum HermexEntry {
    @MainActor static func main() {
        #if DEBUG
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--header-redirect-smoke" {
            Task { @MainActor in
                do { try await ProtocolSmoke.redirects(address: CommandLine.arguments[2], secondAddress: CommandLine.arguments[3]); exit(0) }
                catch { fputs("Fixture redirect smoke failed: \(ConnectionFailure.message(error))\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.count == 3, ["--protocol-smoke", "--protocol-smoke-headers"].contains(CommandLine.arguments[1]) {
            Task { @MainActor in
                do { try await ProtocolSmoke.run(address: CommandLine.arguments[2], requireHeaders: CommandLine.arguments[1] == "--protocol-smoke-headers"); exit(0) }
                catch { fputs("Fixture smoke failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        #endif
        HermexApplication.main()
    }
}
