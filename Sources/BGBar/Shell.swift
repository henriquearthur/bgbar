import Foundation

/// Executa comandos externos fora da main thread, com timeout.
enum Shell {
    struct Result: Sendable {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
    }

    /// PATH estendido: apps abertos pelo Finder herdam um PATH mínimo.
    static let path: String = {
        let home = NSHomeDirectory()
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.orbstack/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let current = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (extra + current).filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    /// Resolve um executável procurando no PATH estendido.
    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `input`, se houver, vai para o stdin do processo (ex.: script para `ssh host sh`).
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 8,
                    input: String? = nil) async -> Result {
        guard let exe = which(executable) else {
            return Result(status: 127, out: "", err: "\(executable): não encontrado")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = path
                env["LC_ALL"] = "C"
                process.environment = env
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let inPipe = input == nil ? nil : Pipe()
                process.standardInput = inPipe ?? FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: Result(status: -1, out: "", err: error.localizedDescription))
                    return
                }
                if let inPipe, let input {
                    signal(SIGPIPE, SIG_IGN) // processo que morre antes de ler não derruba o app
                    // Scripts pequenos: cabem no buffer do pipe, não bloqueiam antes da leitura.
                    try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                // Timeout: SIGTERM e, se ainda assim não sair, SIGKILL 2 s depois
                // (senão a leitura do pipe ficaria presa para sempre).
                let pid = process.processIdentifier
                let killer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { Darwin.kill(pid, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()
                cont.resume(returning: Result(
                    status: process.terminationStatus,
                    out: String(decoding: outData, as: UTF8.self),
                    err: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
