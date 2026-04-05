import os
import threading
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

BRIDGE_DIR = Path(__file__).resolve().parents[2] / "Sources" / "MyMacAgent" / "Advisory" / "Bridge"
import sys

if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

from memograph_advisor import AdvisoryRuntime, ProviderCLIResult, ProviderDiagnostics  # noqa: E402


class ProviderDiagnosticsSingleFlightTests(unittest.TestCase):
    def _make_claude_profiles(self, root: Path, *account_names: str) -> None:
        for account_name in account_names:
            (root / "claude" / account_name / "home" / ".claude").mkdir(parents=True)

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

    def test_accounts_force_refresh_deduplicates_parallel_compute(self) -> None:
        diagnostics = ProviderDiagnostics(probe_timeout_seconds=2)
        call_count = 0
        call_count_lock = threading.Lock()
        barrier = threading.Barrier(5)

        def fake_compute(now: float, force_refresh: bool) -> dict[str, object]:
            nonlocal call_count
            with call_count_lock:
                call_count += 1
            time.sleep(0.15)
            return {
                "profilesDirectory": "/tmp/advisory-profiles",
                "checkedAt": "2026-04-05T00:00:00Z",
                "healthSummary": {
                    "total": 2,
                    "available": 1,
                    "onCooldown": 0,
                },
                "accountsByProvider": {"claude": []},
                "preferredAccounts": {"claude": "acc1"},
            }

        results: list[dict[str, object]] = []
        results_lock = threading.Lock()

        def worker() -> None:
            barrier.wait(timeout=2)
            result = diagnostics.accounts(force_refresh=True)
            with results_lock:
                results.append(result)

        with patch.object(diagnostics, "_compute_accounts_snapshot", side_effect=fake_compute):
            threads = [threading.Thread(target=worker) for _ in range(5)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=2)

        self.assertEqual(call_count, 1)
        self.assertEqual(len(results), 5)
        self.assertTrue(any(result.get("healthSummary", {}).get("available") == 1 for result in results))

    def test_candidate_accounts_use_usage_aware_sorting_over_hot_preferred(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            profiles_root = Path(temp_dir)
            self._make_claude_profiles(profiles_root, "acc1", "acc2", "acc3")

            with patch.dict(os.environ, {"MEMOGRAPH_ADVISOR_PROFILES_DIR": str(profiles_root)}, clear=False):
                runtime = AdvisoryRuntime(probe_timeout_seconds=2)

            runtime.provider_diagnostics._save_preferred_accounts({"claude": "acc1"})
            runtime.provider_diagnostics._account_state["claude:acc1"] = {
                "cooldown_until": 0.0,
                "failure_count": 0,
                "requests_made": 6,
                "last_used_at": 300,
            }
            runtime.provider_diagnostics._account_state["claude:acc2"] = {
                "cooldown_until": 0.0,
                "failure_count": 0,
                "requests_made": 1,
                "last_used_at": 200,
            }
            runtime.provider_diagnostics._account_state["claude:acc3"] = {
                "cooldown_until": 0.0,
                "failure_count": 2,
                "requests_made": 1,
                "last_used_at": 100,
            }

            with patch("memograph_advisor.shutil.which", return_value="/usr/bin/claude"):
                candidates = runtime._candidate_accounts_for_provider("claude")

            self.assertEqual(candidates, ["acc2", "acc3", "acc1"])

    def test_provider_cli_success_records_usage_and_rotates_next_call(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            profiles_root = Path(temp_dir)
            self._make_claude_profiles(profiles_root, "acc1", "acc2")

            with patch.dict(os.environ, {"MEMOGRAPH_ADVISOR_PROFILES_DIR": str(profiles_root)}, clear=False):
                runtime = AdvisoryRuntime(probe_timeout_seconds=2)

            runtime.provider_diagnostics._save_preferred_accounts({"claude": "acc1"})

            chosen_accounts: list[str | None] = []

            def fake_call(
                provider: str,
                prompt: str,
                account_name: str | None = None,
                timeout_seconds: int = 60,
                max_output_length: int = 8000,
            ) -> ProviderCLIResult:
                del provider, prompt, timeout_seconds, max_output_length
                chosen_accounts.append(account_name)
                return ProviderCLIResult(
                    status="ok",
                    detail=f"Used {account_name}",
                    output="ok",
                    account_name=account_name,
                )

            with patch("memograph_advisor.shutil.which", return_value="/usr/bin/claude"):
                with patch.object(runtime, "_call_provider_cli", side_effect=fake_call):
                    first = runtime._run_provider_cli_with_failover("claude", "hello")
                    second = runtime._run_provider_cli_with_failover("claude", "hello again")

            self.assertEqual(first.account_name, "acc1")
            self.assertEqual(second.account_name, "acc2")
            self.assertEqual(chosen_accounts[:2], ["acc1", "acc2"])
            self.assertEqual(runtime.provider_diagnostics._account_state["claude:acc1"]["requests_made"], 1)
            self.assertEqual(runtime.provider_diagnostics._account_state["claude:acc2"]["requests_made"], 1)

    def test_selected_profile_name_prefers_preferences_file_over_bootstrap_env(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            profiles_root = Path(temp_dir)

            with patch.dict(
                os.environ,
                {
                    "MEMOGRAPH_ADVISOR_PROFILES_DIR": str(profiles_root),
                    "MEMOGRAPH_ADVISOR_PROFILE_CLAUDE": "acc1",
                },
                clear=False,
            ):
                runtime = AdvisoryRuntime(probe_timeout_seconds=2)
                runtime.provider_diagnostics._save_preferred_accounts({"claude": "acc2"})
                self.assertEqual(runtime.provider_diagnostics._selected_profile_name("claude"), "acc2")


class AdvisoryRuntimeAuthCheckTests(unittest.TestCase):
    def test_targeted_auth_check_validates_requested_account(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            profiles_root = Path(temp_dir)
            for account_name in ("acc1", "acc2"):
                (profiles_root / "claude" / account_name / "home" / ".claude").mkdir(parents=True)

            with patch.dict(os.environ, {"MEMOGRAPH_ADVISOR_PROFILES_DIR": str(profiles_root)}, clear=False):
                runtime = AdvisoryRuntime(probe_timeout_seconds=2)

            def fake_probe(provider: str, profile_path: Path, now: float) -> dict[str, object]:
                if profile_path.name == "acc1":
                    return {
                        "binaryPresent": True,
                        "sessionDetected": True,
                        "authState": "verified",
                        "detail": "Account available.",
                        "lastError": None,
                        "identity": "person+acc1@example.com",
                    }
                return {
                    "binaryPresent": True,
                    "sessionDetected": True,
                    "authState": "error",
                    "detail": "Account needs reauthorization.",
                    "lastError": "Session expired for acc2.",
                    "identity": "person+acc2@example.com",
                }

            with patch.object(runtime.provider_diagnostics, "_probe_profile_account", side_effect=fake_probe):
                targeted = runtime.check_provider_auth("claude", account_name="acc2", force_refresh=True)
                untargeted = runtime.check_provider_auth("claude", account_name=None, force_refresh=True)

            self.assertFalse(targeted["verified"])
            self.assertEqual(targeted["accountName"], "acc2")
            self.assertEqual(targeted["status"], "session_expired")
            self.assertEqual(targeted["identity"], "person+acc2@example.com")
            self.assertTrue(untargeted["verified"])
            self.assertEqual(untargeted["accountName"], "acc1")


if __name__ == "__main__":
    unittest.main()
