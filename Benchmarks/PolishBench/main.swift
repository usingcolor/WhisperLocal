import Foundation

do {
    try await Bench.main(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("polish-bench: \(error)\n".utf8))
    exit(1)
}
