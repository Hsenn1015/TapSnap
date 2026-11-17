import Foundation
import TapSnapCore

struct FormulaRuntime: Sendable {
    var directory = AppPaths.applicationSupport.appendingPathComponent("formula-runtime", isDirectory: true)
    var resources = Bundle.main.resourceURL

    var python: URL { directory.appendingPathComponent("bin/python") }
    var recognitionScript: URL? { resources?.appendingPathComponent("formula_recognize.py") }

    var isReady: Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path),
              let recognitionScript, FileManager.default.fileExists(atPath: recognitionScript.path),
              let manifest = resources?.appendingPathComponent("formula-models.json"),
              let data = try? Data(contentsOf: manifest),
              let models = try? JSONDecoder().decode([String: String].self, from: data), !models.isEmpty else { return false }
        let checkpoints = directory.appendingPathComponent("lib/python3.12/site-packages/pix2tex/model/checkpoints")
        return models.keys.allSatisfy { model in
            guard let values = try? checkpoints.appendingPathComponent(model).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    var canInstall: Bool {
        guard let resources else { return false }
        return ["setup-formula.sh", "formula-requirements.txt", "formula-models.json", "verify_formula_models.py"]
            .allSatisfy { FileManager.default.fileExists(atPath: resources.appendingPathComponent($0).path) }
    }

    enum Stage: String {
        case environment, dependencies, models, verify

        var title: String {
            switch self {
            case .environment: return "第 1/4 步 · 创建独立运行环境"
            case .dependencies: return "第 2/4 步 · 下载并安装依赖"
            case .models: return "第 3/4 步 · 下载公式识别模型"
            case .verify: return "第 4/4 步 · 校验模型并检查依赖"
            }
        }
    }

    func checkPython(_ complete: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = makeProcess(arguments: ["--find-python"])
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            let available: Bool
            do {
                try task.run()
                task.waitUntilExit()
                available = task.terminationStatus == 0
            } catch {
                available = false
            }
            DispatchQueue.main.async { complete(available) }
        }
    }

    func install(onStage: @escaping (Stage) -> Void, completion: @escaping (Result<Void, Error>) -> Void) throws -> Process {
        guard canInstall, let resources else { throw InstallError.resourcesMissing }
        let task = makeProcess(arguments: [resources.path, directory.path])
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        try? output.fileHandleForWriting.close()

        DispatchQueue.global(qos: .utility).async {
            let reader = output.fileHandleForReading
            defer { try? reader.close() }
            var buffer = Data()
            var recentOutput: [String] = []

            func receiveLine(_ bytes: Data) {
                let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "TAPSNAP_FORMULA_PHASE="
                if line.hasPrefix(prefix), let stage = Stage(rawValue: String(line.dropFirst(prefix.count))) {
                    DispatchQueue.main.async { onStage(stage) }
                } else if !line.isEmpty {
                    recentOutput.append(String(line.prefix(240)))
                    if recentOutput.count > 6 { recentOutput.removeFirst() }
                }
            }

            while true {
                let data = reader.availableData
                guard !data.isEmpty else { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    receiveLine(Data(buffer[..<newline]))
                    buffer.removeSubrange(...newline)
                }
                if buffer.count > 8192 { buffer = Data(buffer.suffix(1024)) }
            }
            if !buffer.isEmpty { receiveLine(buffer) }
            task.waitUntilExit()
            let result: Result<Void, Error> = task.terminationStatus == 0 && isReady
                ? .success(()) : .failure(InstallError.failed(recentOutput.joined(separator: "\n")))
            DispatchQueue.main.async { completion(result) }
        }
        return task
    }

    private func makeProcess(arguments: [String]) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [(resources?.appendingPathComponent("setup-formula.sh").path ?? "")] + arguments
        return task
    }

    enum InstallError: LocalizedError {
        case resourcesMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .resourcesMissing: return "应用包里的公式安装资源不完整。"
            case .failed(let output): return output.isEmpty ? "安装未完成，请检查网络后重试。" : output
            }
        }
    }
}
