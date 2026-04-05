import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

BRIDGE_DIR = Path(__file__).resolve().parents[2] / "Sources" / "MyMacAgent" / "Advisory" / "Bridge"
import sys

if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

from memograph_advisor import ProviderDiagnostics  # noqa: E402


class ProviderDiagnosticsSingleFlightTests(unittest.TestCase):
    def test_force_refresh_deduplicates_parallel_compute(self) -> None:
        diagnostics = ProviderDiagnostics(probe_timeout_seconds=2)
        call_count = 0
        call_count_lock = threading.Lock()
        barrier = threading.Barrier(5)

        def fake_compute() -> dict[str, object]:
            nonlocal call_count
            with call_count_lock:
                call_count += 1
            time.sleep(0.15)
            return {
                "runtimeName": "memograph-advisor",
                "status": "ok",
                "providerName": "claude_cli",
                "transport": "jsonrpc_uds",
                "statusDetail": "Fake provider ready.",
                "lastError": None,
                "recommendedAction": None,
                "activeProviderName": "claude",
                "providerOrder": ["claude"],
                "availableProviders": ["claude"],
                "providerStatuses": [],
                "checkedAt": "2026-04-05T00:00:00Z",
                "runtimeHealthTier": "ok",
                "providerHealthTier": "ok",
            }

        results: list[dict[str, object]] = []
        results_lock = threading.Lock()

        def worker() -> None:
            barrier.wait(timeout=2)
            result = diagnostics.health(force_refresh=True)
            with results_lock:
                results.append(result)

        with patch.object(diagnostics, "_compute_health", side_effect=fake_compute):
            threads = [threading.Thread(target=worker) for _ in range(5)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=2)

        self.assertEqual(call_count, 1)
        self.assertEqual(len(results), 5)
        self.assertTrue(all(isinstance(result, dict) for result in results))
        self.assertTrue(any(result.get("status") == "ok" for result in results))


if __name__ == "__main__":
    unittest.main()
