import Foundation

struct AdvisoryLocalHeuristicRunner {
    func runRecipe(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult? {
        guard case let .ready(runtime) = AdvisorySidecarRuntimeResolver.resolve() else {
            return nil
        }
        guard let payload = try? JSONEncoder().encode(request) else {
            return nil
        }

        let process = Process()
        process.executableURL = runtime.executableURL
        process.arguments = runtime.launchArgumentsPrefix + ["-c", pythonBridgeScript(scriptPath: runtime.scriptPath)]
        process.environment = ProcessInfo.processInfo.environment
            .merging(runtime.baseEnvironment) { _, new in new }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        stdin.fileHandleForWriting.write(payload)
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        guard !output.isEmpty else {
            return nil
        }
        return try? JSONDecoder().decode(AdvisoryRecipeResult.self, from: output)
    }

    private func pythonBridgeScript(scriptPath: String) -> String {
        let quotedScriptPath = jsonStringLiteral(scriptPath)
        return """
import json
import pathlib
import sys

script_path = pathlib.Path(\(quotedScriptPath))
if str(script_path.parent) not in sys.path:
    sys.path.insert(0, str(script_path.parent))

import memograph_advisor as advisor

request = json.loads(sys.stdin.read())
runtime = advisor.AdvisoryRuntime(probe_timeout_seconds=2)
binding = advisor.ExecutionBinding(
    provider_name="",
    account_name=None,
    route_reason="local_stub",
    attempt_index=1,
)
handlers = {
    "continuity_resume": runtime._continuity_resume,
    "thread_maintenance": runtime._thread_maintenance,
    "writing_seed": runtime._writing_seed,
    "tweet_from_thread": runtime._tweet_from_thread,
    "research_direction": runtime._research_direction,
    "weekly_reflection": runtime._weekly_reflection,
    "focus_reflection": runtime._focus_reflection,
    "social_signal": runtime._social_signal,
    "health_pulse": runtime._health_pulse,
    "decision_review": runtime._decision_review,
    "life_admin_review": runtime._life_admin_review,
}

recipe_name = str(request.get("recipeName", "")).strip()
handler = handlers.get(recipe_name)
packet = request.get("packet") or {}
proposals = handler(packet, recipe_name, binding) if handler else []

json.dump(
    {
        "runId": request.get("runId"),
        "artifactProposals": proposals,
        "continuityProposals": [],
        "source": "stub",
    },
    sys.stdout,
    ensure_ascii=False,
)
"""
    }

    private func jsonStringLiteral(_ value: String) -> String {
        let encoded = try? JSONEncoder().encode(value)
        return encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
