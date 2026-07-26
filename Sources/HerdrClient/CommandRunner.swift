import Foundation

/// The result of running a short-lived helper process to completion.
public struct CommandOutput: Sendable, Equatable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(status: Int32, standardOutput: Data, standardError: Data) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var isSuccess: Bool { status == 0 }

    /// stderr as a trimmed string, for surfacing a failure to the user.
    public var errorMessage: String {
        String(decoding: standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum CommandFailure: Error, Sendable, Equatable {
    case launchFailed(executable: String, message: String)
}

extension CommandFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, message):
            "Couldn't run \(executable): \(message)"
        }
    }
}

/// Runs a helper process and waits for it. Injectable so discovery logic can be
/// tested without touching the real `herdr`/`ssh` binaries.
public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) throws -> CommandOutput
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw CommandFailure.launchFailed(
                executable: executable, message: String(describing: error))
        }
        // Drain both pipes concurrently. Reading them sequentially can still
        // deadlock: a child may fill stderr while we wait for stdout to reach EOF.
        let outputDrain = CommandPipeDrain(handle: out.fileHandleForReading)
        let errorDrain = CommandPipeDrain(handle: err.fileHandleForReading)
        let drains = DispatchGroup()
        for drain in [outputDrain, errorDrain] {
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                drain.readToEnd()
                drains.leave()
            }
        }
        drains.wait()
        process.waitUntilExit()
        return CommandOutput(
            status: process.terminationStatus,
            standardOutput: outputDrain.data,
            standardError: errorDrain.data)
    }
}

/// Owns one pipe read so the two blocking drains can safely run in parallel.
private final class CommandPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var captured = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() {
        let data = handle.readDataToEndOfFile()
        lock.lock()
        captured = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

/// Finds a CLI binary by absolute path.
///
/// NotchApp is a GUI accessory app. Launched at login it inherits a minimal
/// environment whose `PATH` excludes every common user install prefix — and
/// `herdr` installs to `~/.local/bin` by default — so `/usr/bin/env herdr` is not
/// enough. The probe order mirrors the prefixes herdr's own remote-attach uses:
/// direct, Homebrew, mise, and Nix profile paths.
public enum ExecutableLocator {
    /// Overrides the probe entirely, for debugging a GUI launch.
    public static let overrideEnvironmentKey = "NOTCHAGENT_HERDR_BINARY"

    public static func locate(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = Self.isExecutableFile
    ) -> String? {
        if name == "herdr", let override = environment[overrideEnvironmentKey],
           !override.isEmpty, isExecutable(override) {
            return override
        }
        for directory in searchDirectories(environment: environment) {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// `PATH` first (it reflects an explicit user choice when we *do* have one),
    /// then the well-known install prefixes a GUI launch would otherwise miss.
    static func searchDirectories(environment: [String: String]) -> [String] {
        var directories: [String] = []
        var seen: Set<String> = []
        func append(_ path: String) {
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.isEmpty, seen.insert(expanded).inserted else { return }
            directories.append(expanded)
        }
        for entry in (environment["PATH"] ?? "").split(separator: ":") {
            append(String(entry))
        }
        let home = environment["HOME"].map { ($0 as NSString) }
        for suffix in [
            ".local/bin", ".cargo/bin", ".local/share/mise/shims", ".nix-profile/bin",
        ] {
            if let home { append(home.appendingPathComponent(suffix)) }
        }
        for path in [
            "/opt/homebrew/bin", "/usr/local/bin", "/run/current-system/sw/bin",
            "/usr/bin", "/bin",
        ] {
            append(path)
        }
        return directories
    }

    public static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
