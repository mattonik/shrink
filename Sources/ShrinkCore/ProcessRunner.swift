import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let standardError: String

    func failureMessage(tool: String) -> String {
        let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "\(tool) exited with code \(status)" : detail
    }
}

/// `Process` is not Sendable, but `terminate()` is safe from any thread; the
/// box only exists so the cancellation handler can reach it.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Runs `executable`, handing each line of stdout to `onLine` as it arrives,
/// and returns the exit status with the collected stderr.
///
/// Nothing here blocks a thread. Pipe data arrives through
/// `readabilityHandler` and the exit through `terminationHandler`, both on
/// Foundation's own queues. Blocking reads or `waitUntilExit()` would park
/// Swift's small cooperative thread pool, and with a few conversions in flight
/// the work they wait on can never be scheduled — the run simply hangs.
///
/// Cancelling the calling task terminates the process and throws
/// `CancellationError`. The process is launched from an argument array with no
/// shell in between, so file names can never be interpreted as commands.
/// `environment` replaces the inherited one when given.
func runStreamingLines(
    executable: URL,
    arguments: [String],
    environment: [String: String]? = nil,
    onLine: (String) -> Void
) async throws -> ProcessResult {
    try Task.checkCancellation()

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let environment { process.environment = environment }
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.standardInput = FileHandle.nullDevice

    let output = chunks(from: outputPipe.fileHandleForReading)
    let errors = chunks(from: errorPipe.fileHandleForReading)
    let (exit, exitContinuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
    process.terminationHandler = { finished in
        exitContinuation.yield(finished.terminationStatus)
        exitContinuation.finish()
    }
    let box = ProcessBox(process)

    return try await withTaskCancellationHandler {
        do {
            try process.run()
        } catch {
            throw TranscodeError.failed(error.localizedDescription)
        }

        // Drain stderr alongside stdout: a tool blocks once a pipe buffer
        // fills, so an unread error log would stall it forever.
        async let errorData = collect(errors)

        var pending = Data()
        for await chunk in output {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                onLine(decodeLine(pending[pending.startIndex..<newline]))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { onLine(decodeLine(pending)) }

        var status: Int32 = -1
        for await code in exit { status = code }
        let standardError = String(decoding: await errorData, as: UTF8.self)

        try Task.checkCancellation()
        return ProcessResult(status: status, standardError: standardError)
    } onCancel: {
        if box.process.isRunning { box.process.terminate() }
    }
}

/// Runs `executable` to completion and returns its whole stdout.
func runCollectingOutput(
    executable: URL, arguments: [String], environment: [String: String]? = nil
) async throws -> Data {
    var lines: [String] = []
    let result = try await runStreamingLines(
        executable: executable, arguments: arguments, environment: environment
    ) { lines.append($0) }
    guard result.status == 0 else {
        throw TranscodeError.failed(result.failureMessage(tool: executable.lastPathComponent))
    }
    return Data(lines.joined(separator: "\n").utf8)
}

private func chunks(from handle: FileHandle) -> AsyncStream<Data> {
    AsyncStream { continuation in
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {  // end of file
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
    }
}

private func collect(_ stream: AsyncStream<Data>) async -> Data {
    var data = Data()
    for await chunk in stream { data.append(chunk) }
    return data
}

/// One line of tool output, without a trailing carriage return.
private func decodeLine(_ bytes: Data) -> String {
    let line = String(decoding: bytes, as: UTF8.self)
    return line.hasSuffix("\r") ? String(line.dropLast()) : line
}
