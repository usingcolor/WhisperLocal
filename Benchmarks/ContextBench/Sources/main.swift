import Foundation

// Progress lines should appear as they happen, not when a pipe's buffer fills.
setvbuf(stdout, nil, _IOLBF, 0)

do {
    try await ContextBench.main(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
