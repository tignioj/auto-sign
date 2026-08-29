import Foundation

enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("autosign-command-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: outputURL)
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: outputURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try handle.synchronize()
            let data = (try? Data(contentsOf: outputURL)) ?? Data()
            return CommandResult(status: process.terminationStatus, data: data)
        }.value
    }

    static func checked(_ executable: String, _ arguments: [String], context: String) async throws -> CommandResult {
        let result = try await run(executable, arguments)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AutoSignError.command(detail.isEmpty ? context : "\(context)\n\(detail)")
        }
        return result
    }
}
