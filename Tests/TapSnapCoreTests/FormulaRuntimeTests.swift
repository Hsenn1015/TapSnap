import Foundation
import XCTest
@testable import TapSnapApp

final class FormulaRuntimeTests: XCTestCase {
    func testExecutableAloneDoesNotMakeAnIncompleteRuntimeReady() throws {
        let runtime = try fixture()
        let checkpoints = runtime.directory.appendingPathComponent("lib/python3.12/site-packages/pix2tex/model/checkpoints")
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime.python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/bash\n".utf8).write(to: runtime.python)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.python.path)
        XCTAssertFalse(runtime.isReady)

        try Data([1]).write(to: checkpoints.appendingPathComponent("weights.pth"))
        try Data().write(to: checkpoints.appendingPathComponent("image_resizer.pth"))
        XCTAssertFalse(runtime.isReady)
        try Data([1]).write(to: checkpoints.appendingPathComponent("image_resizer.pth"))
        XCTAssertTrue(runtime.isReady)
    }

    func testInstallationRelaysStagesAndWaitsForReadyRuntime() throws {
        let runtime = try fixture()
        let script = """
        set -eu
        [ "$#" -eq 2 ]
        printf '%s\\n' TAPSNAP_FORMULA_PHASE=environment TAPSNAP_FORMULA_PHASE=dependencies
        printf '%s\\n' TAPSNAP_FORMULA_PHASE=models TAPSNAP_FORMULA_PHASE=verify
        checkpoints="$2/lib/python3.12/site-packages/pix2tex/model/checkpoints"
        mkdir -p "$2/bin" "$checkpoints"
        printf '#!/bin/bash\\n' > "$2/bin/python"
        chmod 700 "$2/bin/python"
        printf 'weights' > "$checkpoints/weights.pth"
        printf 'resizer' > "$checkpoints/image_resizer.pth"
        """
        try Data(script.utf8).write(to: XCTUnwrap(runtime.resources).appendingPathComponent("setup-formula.sh"))
        let completed = expectation(description: "安装进程退出")
        var stages: [FormulaRuntime.Stage] = []
        let process = try runtime.install(onStage: { stages.append($0) }) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(stages, [.environment, .dependencies, .models, .verify])
        XCTAssertTrue(runtime.isReady)
    }

    private func fixture() throws -> FormulaRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TapSnap-FormulaTest-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(#"{"weights.pth":"fixture","image_resizer.pth":"fixture"}"#.utf8)
            .write(to: resources.appendingPathComponent("formula-models.json"))
        for name in ["formula_recognize.py", "formula-requirements.txt", "verify_formula_models.py"] {
            try Data().write(to: resources.appendingPathComponent(name))
        }
        return FormulaRuntime(directory: root.appendingPathComponent("runtime"), resources: resources)
    }
}
