#!/usr/bin/env python3
from __future__ import annotations

import argparse
import calendar
import json
import logging
import math
import os
import re
import shlex
import shutil
import signal
import socketserver
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger("memograph_advisor")

RETRYABLE_ACCOUNT_FAILURE_STATUSES = {
    "timeout",
    "unavailable",
    "cli_generation_failed",
    "cooldown",
    "empty_output",
    "rate_limited",
}

TERMINAL_ACCOUNT_FAILURE_STATUSES = {
    "binary_missing",
    "session_expired",
    "session_missing",
}


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from provider_sessions import (
    VALID_PROVIDERS,
    get_account_label,
    import_current_session,
    open_login_terminal,
    open_login_terminal_for_profile,
    profile_login_environment,
    set_account_label,
)


class JsonRPCMethodError(Exception):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _read_json_file(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


class ProviderDiagnostics:
    def __init__(self, probe_timeout_seconds: int) -> None:
        self.probe_timeout_seconds = max(2, probe_timeout_seconds)
        self._snapshot_lock = threading.Lock()
        self._cached_health: dict[str, Any] | None = None
        self._checked_at = 0.0
        self._refresh_in_progress = False
        self._cache_ttl_seconds = max(15.0, float(os.getenv("MEMOGRAPH_ADVISOR_HEALTH_CACHE_TTL", "30")))
        self._provider_state: dict[str, dict[str, Any]] = {}
        configured_profiles_dir = os.getenv("MEMOGRAPH_ADVISOR_PROFILES_DIR", "").strip()
        if configured_profiles_dir:
            self._profiles_dir = Path(configured_profiles_dir).expanduser()
        elif (Path.home() / ".cli-profiles").exists():
            self._profiles_dir = (Path.home() / ".cli-profiles").expanduser()
        else:
            self._profiles_dir = (Path.home() / "Library" / "Application Support" / "MyMacAgent" / "advisory-provider-profiles").expanduser()
        self._fake_provider_statuses = self._parse_fake_provider_statuses(
            os.getenv("MEMOGRAPH_ADVISOR_FAKE_PROVIDER_STATUSES", "").strip()
        )
        self._fake_run_failures = self._parse_fake_run_failures(
            os.getenv("MEMOGRAPH_ADVISOR_FAKE_RUN_FAILURES", "").strip()
        )
        self._provider_cooldown_seconds = self._read_int_env(
            [
                "MEMOGRAPH_ADVISOR_PROVIDER_COOLDOWN_SECONDS",
                "MEMOGRAPH_ADVISOR_RUN_COOLDOWN_SECONDS",
                "MEMOGRAPH_ADVISOR_FAILOVER_COOLDOWN_SECONDS",
            ],
            default=30,
            minimum=3,
            maximum=300,
        )
        self._run_attempt_budget = self._read_int_env(
            [
                "MEMOGRAPH_ADVISOR_RUN_ATTEMPT_BUDGET",
                "MEMOGRAPH_ADVISOR_MAX_PROVIDER_ATTEMPTS",
                "MEMOGRAPH_ADVISOR_PROVIDER_ATTEMPT_BUDGET",
            ],
            default=max(1, len(self._provider_order())),
            minimum=1,
            maximum=16,
        )
        self._account_state: dict[str, dict[str, Any]] = {}
        self._cached_accounts: dict[str, Any] | None = None
        self._accounts_checked_at = 0.0
        self._accounts_refresh_in_progress = False

    def profiles_dir(self) -> Path:
        return self._profiles_dir

    def source_home(self) -> Path:
        configured = os.getenv("MEMOGRAPH_ADVISOR_SOURCE_HOME", "").strip()
        if configured:
            return Path(configured).expanduser()
        return Path.home()

    def preferred_accounts_path(self) -> Path:
        return self.profiles_dir() / ".memograph-account-preferences.json"

    def _load_preferred_accounts(self) -> dict[str, str]:
        raw = _read_json_file(self.preferred_accounts_path())
        if not isinstance(raw, dict):
            return {}
        preferred = raw.get("preferredAccounts")
        if not isinstance(preferred, dict):
            return {}
        return {
            str(provider).strip().lower(): str(account_name).strip()
            for provider, account_name in preferred.items()
            if str(provider).strip() and str(account_name).strip()
        }

    def _save_preferred_accounts(self, preferred_accounts: dict[str, str]) -> None:
        path = self.preferred_accounts_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "preferredAccounts": {
                str(provider): str(account_name)
                for provider, account_name in preferred_accounts.items()
                if str(provider).strip() and str(account_name).strip()
            }
        }
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")

    def _set_preferred_account_locked(self, provider: str, account_name: str) -> None:
        preferred_accounts = self._load_preferred_accounts()
        preferred_accounts[provider] = account_name
        self._save_preferred_accounts(preferred_accounts)
        with self._snapshot_lock:
            self._invalidate_cache()

    def _record_account_use_locked(
        self,
        provider: str,
        account_name: str | None = None,
        now: float | None = None,
    ) -> None:
        account_name = account_name or self._selected_profile_name(provider)
        if not account_name:
            return
        state_key = self._profile_account_key(provider, account_name)
        recorded_at = float(now if now is not None else time.time())
        checked_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(recorded_at))
        with self._snapshot_lock:
            state = self._account_state.setdefault(state_key, {"cooldown_until": 0.0, "failure_count": 0, "requests_made": 0})
            state["requests_made"] = int(state.get("requests_made", 0)) + 1
            state["last_used_at"] = int(recorded_at)
            state["last_checked_at"] = checked_at
            state["cooldown_until"] = 0.0
            state["last_failure_status"] = None
            state["last_failure_detail"] = None
            state["failure_count"] = 0
            self._invalidate_accounts_cache_locked()

    def _record_provider_success_locked(self, provider: str, now: float | None = None) -> None:
        recorded_at = float(now if now is not None else time.time())
        checked_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(recorded_at))
        with self._snapshot_lock:
            state = self._provider_state.setdefault(provider, {"cooldown_until": 0.0, "failure_count": 0})
            state["cooldown_until"] = 0.0
            state["last_failure_status"] = None
            state["last_failure_detail"] = None
            state["failure_count"] = 0
            state["last_checked_at"] = checked_at
            self._invalidate_cache()

    def _profile_account_key(self, provider: str, account_name: str) -> str:
        return f"{provider}:{account_name}"

    def _profile_directories(self, provider: str) -> list[Path]:
        provider_dir = self.profiles_dir() / provider
        if not provider_dir.exists():
            return []

        result: list[Path] = []
        for candidate in sorted(provider_dir.iterdir()):
            if not candidate.is_dir() or not candidate.name.startswith("acc"):
                continue
            if provider == "codex":
                if (candidate / "auth.json").exists() or (candidate / "config.toml").exists():
                    result.append(candidate)
            elif provider in {"claude", "gemini"}:
                if (candidate / "home").exists():
                    result.append(candidate)
        return result

    def _profile_directory(self, provider: str, account_name: str) -> Path:
        path = self.profiles_dir() / provider / account_name
        if not path.exists():
            raise FileNotFoundError(f"Unknown {provider} account: {account_name}")
        return path

    def _profile_config_dir(self, provider: str, profile_path: Path) -> str:
        if provider == "codex":
            return str(profile_path)
        if provider == "claude":
            return str(profile_path / "home" / ".claude")
        if provider == "gemini":
            primary = profile_path / "home" / ".gemini"
            xdg = profile_path / "home" / ".config" / "gemini"
            if primary.exists():
                return str(primary)
            if xdg.exists():
                return str(xdg)
            return str(primary)
        return str(profile_path)

    def _profile_has_session_marker(self, provider: str, profile_path: Path) -> bool:
        if provider == "codex":
            return (profile_path / "auth.json").exists() or (profile_path / "config.toml").exists()
        if provider == "claude":
            return (profile_path / "home" / ".claude").exists()
        if provider == "gemini":
            return (profile_path / "home" / ".gemini").exists() or (profile_path / "home" / ".config" / "gemini").exists()
        return False

    def _profile_identity_hint(self, provider: str, profile_path: Path) -> str:
        if provider == "gemini":
            data = _read_json_file(profile_path / "home" / ".gemini" / "google_accounts.json")
            if isinstance(data, dict):
                active = str(data.get("active", "")).strip()
                if active:
                    return active
        if provider == "claude":
            credentials = _read_json_file(profile_path / "home" / ".claude" / ".credentials.json")
            if isinstance(credentials, dict):
                oauth = credentials.get("claudeAiOauth")
                if isinstance(oauth, dict):
                    maybe_email = str(oauth.get("email", "")).strip()
                    if maybe_email:
                        return maybe_email
        if provider == "codex":
            auth_data = _read_json_file(profile_path / "auth.json")
            if isinstance(auth_data, dict):
                email = str(auth_data.get("email", "")).strip()
                if email:
                    return email
                user = str(auth_data.get("user", "")).strip()
                if user:
                    return user
            config_path = profile_path / "config.toml"
            if config_path.exists():
                try:
                    content = config_path.read_text(encoding="utf-8")
                    for line in content.splitlines():
                        if line.strip().startswith("email") and "=" in line:
                            return line.split("=", 1)[1].strip().strip('"').strip("'")
                except OSError:
                    pass
        return ""

    def _ensure_gemini_auth_settings(self, home_dir: Path) -> None:
        gemini_dir = home_dir / ".gemini"
        settings_path = gemini_dir / "settings.json"
        oauth_path = gemini_dir / "oauth_creds.json"
        if not oauth_path.exists():
            return

        data: dict[str, Any]
        try:
            if settings_path.exists():
                loaded = json.loads(settings_path.read_text(encoding="utf-8"))
                data = loaded if isinstance(loaded, dict) else {}
            else:
                data = {}
        except (OSError, json.JSONDecodeError):
            data = {}

        security = data.setdefault("security", {})
        if not isinstance(security, dict):
            security = {}
            data["security"] = security
        auth = security.setdefault("auth", {})
        if not isinstance(auth, dict):
            auth = {}
            security["auth"] = auth
        if str(auth.get("selectedType", "")).strip():
            return

        auth["selectedType"] = "oauth-personal"
        try:
            gemini_dir.mkdir(parents=True, exist_ok=True)
            settings_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        except OSError:
            return

    def _starting_health_snapshot(self, now: float | None = None, refresh_in_progress: bool = True) -> dict[str, Any]:
        checked_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now or time.time()))
        provider_order = self._provider_order()
        result = self._make_health(
            status="starting",
            provider_name="sidecar_jsonrpc_uds",
            status_detail="Initial advisory health refresh in progress.",
            last_error=None,
            active_provider_name=None,
            provider_order=provider_order,
            available_providers=[],
            provider_statuses=[],
            checked_at=checked_at,
            runtime_health_tier="starting",
            provider_health_tier="starting",
        )
        result["isStale"] = True
        result["stalenessSeconds"] = 0
        result["refreshInProgress"] = refresh_in_progress
        return result

    def health(self, force_refresh: bool = False) -> dict[str, Any]:
        with self._snapshot_lock:
            now = time.time()
            cached = self._cached_health
            checked_at = self._checked_at
            stale = cached is None or (now - checked_at) >= self._health_cache_ttl_seconds(cached, now)
            refresh_running = self._refresh_in_progress

        if not force_refresh and cached is not None:
            result = dict(cached)
            if stale and not refresh_running:
                self._trigger_background_refresh()
                refresh_running = True
            result["isStale"] = stale
            result["stalenessSeconds"] = int(now - checked_at) if checked_at else 0
            result["refreshInProgress"] = refresh_running
            return result

        if not force_refresh:
            if not refresh_running:
                self._trigger_background_refresh()
                refresh_running = True
            return self._starting_health_snapshot(now=now, refresh_in_progress=refresh_running)

        return self._do_synchronous_refresh()

    def _trigger_background_refresh(self) -> None:
        with self._snapshot_lock:
            if self._refresh_in_progress:
                return
            self._refresh_in_progress = True

        thread = threading.Thread(target=self._background_refresh, daemon=True)
        thread.start()

    def _background_refresh(self) -> None:
        try:
            computed = self._compute_health()  # runs OUTSIDE any lock
            with self._snapshot_lock:
                self._cached_health = dict(computed)
                self._checked_at = time.time()
        except Exception:
            logger.exception("Background health refresh failed")
        finally:
            with self._snapshot_lock:
                self._refresh_in_progress = False

    def _do_synchronous_refresh(self) -> dict[str, Any]:
        requested_at = time.time()
        deadline = time.time() + min(1.0, max(0.25, self.probe_timeout_seconds * 0.25))
        claimed_refresh_slot = False

        while True:
            with self._snapshot_lock:
                cached = dict(self._cached_health) if self._cached_health is not None else None
                checked_at = self._checked_at
                if not self._refresh_in_progress:
                    if cached is not None and checked_at >= requested_at:
                        cached["isStale"] = False
                        cached["refreshInProgress"] = False
                        cached["stalenessSeconds"] = 0
                        return cached
                    self._refresh_in_progress = True
                    claimed_refresh_slot = True
                    break

            if cached is not None:
                cached["isStale"] = True
                cached["refreshInProgress"] = True
                cached["stalenessSeconds"] = int(max(0, time.time() - checked_at)) if checked_at else 0
                return cached

            if time.time() >= deadline:
                now = time.time()
                return self._starting_health_snapshot(now=now, refresh_in_progress=True)

            time.sleep(0.02)

        try:
            computed = self._compute_health()  # OUTSIDE lock
            now = time.time()
            with self._snapshot_lock:
                self._cached_health = dict(computed)
                self._checked_at = now
            result = dict(computed)
            result["isStale"] = False
            result["stalenessSeconds"] = 0
            result["refreshInProgress"] = False
            return result
        finally:
            if claimed_refresh_slot:
                with self._snapshot_lock:
                    self._refresh_in_progress = False

    def _quick_provider_check(self) -> dict[str, Any] | None:
        """Return cached health if a runnable provider exists, else None."""
        with self._snapshot_lock:
            if self._cached_health is None:
                return None
            health = dict(self._cached_health)
            if health.get("status") != "ok":
                return None
            active = str(health.get("activeProviderName") or "").strip().lower()
            if not active:
                return None
            state = self._provider_state.get(active, {})
            cooldown_until = float(state.get("cooldown_until", 0.0))
            if time.time() < cooldown_until:
                return None
            return health

    def accounts(self, force_refresh: bool = False) -> dict[str, Any]:
        if force_refresh:
            return self._do_synchronous_accounts_refresh()

        with self._snapshot_lock:
            now = time.time()
            if (
                not force_refresh
                and self._cached_accounts is not None
                and (now - self._accounts_checked_at) < 5.0
            ):
                return json.loads(json.dumps(self._cached_accounts))

        computed = self._compute_accounts_snapshot(now=now, force_refresh=force_refresh)
        with self._snapshot_lock:
            self._cached_accounts = json.loads(json.dumps(computed))
            self._accounts_checked_at = now
        return computed

    def _starting_accounts_snapshot(self, now: float | None = None, refresh_in_progress: bool = True) -> dict[str, Any]:
        return {
            "profilesDirectory": str(self.profiles_dir()),
            "checkedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now or time.time())),
            "healthSummary": {
                "total": 0,
                "available": 0,
                "onCooldown": 0,
            },
            "accountsByProvider": {},
            "preferredAccounts": self._load_preferred_accounts(),
            "isStale": True,
            "stalenessSeconds": 0,
            "refreshInProgress": refresh_in_progress,
        }

    def _do_synchronous_accounts_refresh(self) -> dict[str, Any]:
        requested_at = time.time()
        deadline = time.time() + min(1.0, max(0.25, self.probe_timeout_seconds * 0.25))
        claimed_refresh_slot = False

        while True:
            with self._snapshot_lock:
                cached = json.loads(json.dumps(self._cached_accounts)) if self._cached_accounts is not None else None
                checked_at = self._accounts_checked_at
                if not self._accounts_refresh_in_progress:
                    if cached is not None and checked_at >= requested_at:
                        cached["isStale"] = False
                        cached["refreshInProgress"] = False
                        cached["stalenessSeconds"] = 0
                        return cached
                    self._accounts_refresh_in_progress = True
                    claimed_refresh_slot = True
                    break

            if cached is not None:
                cached["isStale"] = True
                cached["refreshInProgress"] = True
                cached["stalenessSeconds"] = int(max(0, time.time() - checked_at)) if checked_at else 0
                return cached

            if time.time() >= deadline:
                now = time.time()
                return self._starting_accounts_snapshot(now=now, refresh_in_progress=True)

            time.sleep(0.02)

        try:
            computed = self._compute_accounts_snapshot(now=time.time(), force_refresh=True)
            checked_at = time.time()
            with self._snapshot_lock:
                self._cached_accounts = json.loads(json.dumps(computed))
                self._accounts_checked_at = checked_at
            result = json.loads(json.dumps(computed))
            result["isStale"] = False
            result["stalenessSeconds"] = 0
            result["refreshInProgress"] = False
            return result
        finally:
            if claimed_refresh_slot:
                with self._snapshot_lock:
                    self._accounts_refresh_in_progress = False

    def _compute_accounts_snapshot(self, now: float, force_refresh: bool) -> dict[str, Any]:
        checked_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
        preferred_accounts = self._load_preferred_accounts()
        accounts_by_provider: dict[str, list[dict[str, Any]]] = {}
        total = 0
        available = 0
        on_cooldown = 0

        for provider in VALID_PROVIDERS:
            provider_accounts: list[dict[str, Any]] = []
            for profile_path in self._profile_directories(provider):
                snapshot = self._profile_account_snapshot(
                    provider=provider,
                    profile_path=profile_path,
                    preferred_account_name=preferred_accounts.get(provider),
                    now=now,
                    checked_at=checked_at,
                    force_refresh=force_refresh,
                )
                provider_accounts.append(snapshot)
                total += 1
                if snapshot.get("available"):
                    available += 1
                if int(snapshot.get("cooldownRemainingSeconds") or 0) > 0:
                    on_cooldown += 1
            accounts_by_provider[provider] = provider_accounts

        return {
            "profilesDirectory": str(self.profiles_dir()),
            "checkedAt": checked_at,
            "healthSummary": {
                "total": total,
                "available": available,
                "onCooldown": on_cooldown,
            },
            "accountsByProvider": accounts_by_provider,
            "preferredAccounts": preferred_accounts,
        }

    def _profile_account_snapshot(
        self,
        provider: str,
        profile_path: Path,
        preferred_account_name: str | None,
        now: float,
        checked_at: str,
        force_refresh: bool,
    ) -> dict[str, Any]:
        account_name = profile_path.name
        state_key = self._profile_account_key(provider, account_name)
        state = self._account_state.setdefault(state_key, {"cooldown_until": 0.0, "failure_count": 0, "requests_made": 0})
        cooldown_remaining, _ = self._cooldown_snapshot(state, now)
        binary_present = shutil.which(self._provider_binary(provider)) is not None
        session_detected = self._profile_has_session_marker(provider, profile_path)
        label = get_account_label(self.profiles_dir(), provider, account_name)
        identity_hint = self._profile_identity_hint(provider, profile_path)
        detail = self._normalize_optional_text(state.get("last_failure_detail"))
        last_error = detail if state.get("last_failure_status") else None
        auth_state = "unknown"
        last_failure_status = str(state.get("last_failure_status") or "").strip().lower()
        should_probe = (
            binary_present
            and session_detected
            and (
                force_refresh
                or not state.get("last_checked_at")
                or (cooldown_remaining == 0 and self._account_failure_is_retryable(last_failure_status))
            )
        )

        if provider == "gemini":
            self._ensure_gemini_auth_settings(profile_path / "home")

        if should_probe:
            result = self._probe_profile_account(provider, profile_path, now)
            binary_present = bool(result["binaryPresent"])
            session_detected = bool(result["sessionDetected"])
            auth_state = str(result["authState"])
            detail = result.get("detail")
            last_error = result.get("lastError")
            if result.get("identity"):
                identity_hint = result["identity"]
        else:
            if not binary_present or not session_detected or last_failure_status:
                auth_state = "error"
            elif state.get("last_checked_at"):
                auth_state = "verified"
                detail = "Account verified."

        available = binary_present and session_detected and auth_state == "verified" and cooldown_remaining == 0
        if available:
            detail = detail or "Account available."
            last_error = None
        elif not detail:
            if not binary_present:
                detail = f"{provider} CLI is not installed."
            elif not session_detected:
                detail = "No imported session detected for this account."
            elif cooldown_remaining > 0:
                detail = f"Cooling down for {cooldown_remaining}s."
            else:
                detail = "Account needs reauthorization."

        return {
            "providerName": provider,
            "accountName": account_name,
            "label": label or None,
            "identity": identity_hint or None,
            "detail": detail,
            "authState": auth_state,
            "available": available,
            "preferred": preferred_account_name == account_name,
            "binaryPresent": binary_present,
            "sessionDetected": session_detected,
            "cooldownRemainingSeconds": cooldown_remaining if cooldown_remaining > 0 else None,
            "lastError": last_error,
            "requestsMade": int(state.get("requests_made", 0)),
            "lastUsedAt": int(state.get("last_used_at", 0)) or None,
            "lastCheckedAt": str(state.get("last_checked_at") or checked_at),
            "profilePath": str(profile_path),
            "configDirectory": self._profile_config_dir(provider, profile_path),
        }

    def _probe_profile_account(self, provider: str, profile_path: Path, now: float) -> dict[str, Any]:
        account_name = profile_path.name
        state_key = self._profile_account_key(provider, account_name)
        state = self._account_state.setdefault(state_key, {"cooldown_until": 0.0, "failure_count": 0, "requests_made": 0})
        env = os.environ.copy()
        env.update(profile_login_environment(provider, profile_path, real_home=self.source_home()))

        try:
            result = self._probe_provider(provider, env=env)
        except subprocess.TimeoutExpired:
            detail = f"{provider}/{account_name} CLI probe timed out"
            self._record_account_failure_locked(state_key=state_key, status="timeout", detail=detail, now=now)
            return {
                "binaryPresent": True,
                "sessionDetected": True,
                "authState": "error",
                "detail": detail,
                "lastError": detail,
                "identity": None,
            }
        except Exception as exc:
            detail = f"{provider}/{account_name} probe failed: {exc}"
            self._record_account_failure_locked(state_key=state_key, status="unavailable", detail=detail, now=now)
            return {
                "binaryPresent": True,
                "sessionDetected": True,
                "authState": "error",
                "detail": detail,
                "lastError": detail,
                "identity": None,
            }

        status = str(result.get("status") or "unavailable").strip().lower() or "unavailable"
        detail = str(result.get("detail") or f"{provider}/{account_name} unavailable.").strip()
        identity = self._normalize_optional_text(result.get("accountIdentity"))
        checked_at_str = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))

        if status == "ok":
            with self._snapshot_lock:
                state["last_checked_at"] = checked_at_str
                state["cooldown_until"] = 0.0
                state["last_failure_status"] = None
                state["last_failure_detail"] = None
                state["failure_count"] = 0
            return {
                "binaryPresent": True,
                "sessionDetected": True,
                "authState": "verified",
                "detail": detail,
                "lastError": None,
                "identity": identity,
            }

        with self._snapshot_lock:
            state["last_checked_at"] = checked_at_str
        self._record_account_failure_locked(state_key=state_key, status=status, detail=detail, now=now)
        return {
            "binaryPresent": True,
            "sessionDetected": True,
            "authState": "error",
            "detail": detail,
            "lastError": detail,
            "identity": identity,
        }

    def _compute_health(self) -> dict[str, Any]:
        forced_status = os.getenv("MEMOGRAPH_ADVISOR_FORCE_STATUS", "").strip().lower()
        forced_detail = os.getenv("MEMOGRAPH_ADVISOR_FORCE_DETAIL", "").strip()
        fake_provider = os.getenv("MEMOGRAPH_ADVISOR_FAKE_PROVIDER", "").strip().lower()
        provider_order = self._provider_order()
        checked_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        if forced_status:
            return self._make_health(
                status=forced_status,
                provider_name=fake_provider or "sidecar_jsonrpc_uds",
                status_detail=forced_detail or f"Forced sidecar status: {forced_status}",
                last_error=forced_detail or f"Forced sidecar status: {forced_status}",
                active_provider_name=fake_provider or None,
                provider_order=provider_order,
                available_providers=[fake_provider] if fake_provider else [],
                provider_statuses=(
                    [
                        self._provider_snapshot(
                            provider=fake_provider,
                            status=forced_status,
                            detail=forced_detail or f"Forced sidecar status: {forced_status}",
                            binary_present=True,
                            session_detected=True,
                            priority=0,
                        )
                    ]
                    if fake_provider
                    else []
                ),
                checked_at=checked_at,
            )

        if self._uses_fake_routing_mode():
            return self._compute_fake_routed_health(
                fake_provider=fake_provider,
                provider_order=provider_order,
                checked_at=checked_at,
            )

        if fake_provider:
            return self._make_health(
                status="ok",
                provider_name=f"{fake_provider}_cli_fake",
                status_detail="Using deterministic fake provider mode for memograph-advisor.",
                last_error=None,
                active_provider_name=fake_provider,
                provider_order=provider_order,
                available_providers=[fake_provider],
                provider_statuses=[
                    self._provider_snapshot(
                        provider=fake_provider,
                        status="ok",
                        detail="Using deterministic fake provider mode for memograph-advisor.",
                        binary_present=True,
                        session_detected=True,
                        priority=0,
                    )
                ],
                checked_at=checked_at,
            )

        return self._compute_real_health(provider_order=provider_order, checked_at=checked_at)

    def _make_health(
        self,
        status: str,
        provider_name: str,
        status_detail: str | None,
        last_error: str | None,
        active_provider_name: str | None = None,
        provider_order: list[str] | None = None,
        available_providers: list[str] | None = None,
        provider_statuses: list[dict[str, Any]] | None = None,
        checked_at: str | None = None,
        runtime_health_tier: str = "ok",
        provider_health_tier: str | None = None,
    ) -> dict[str, Any]:
        return {
            "runtimeName": "memograph-advisor",
            "status": status,
            "providerName": provider_name,
            "transport": "jsonrpc_uds",
            "statusDetail": status_detail,
            "lastError": last_error,
            "recommendedAction": None,
            "activeProviderName": active_provider_name,
            "providerOrder": provider_order or [],
            "availableProviders": available_providers or [],
            "providerStatuses": provider_statuses or [],
            "checkedAt": checked_at,
            "runtimeHealthTier": runtime_health_tier,
            "providerHealthTier": provider_health_tier or ("ok" if status == "ok" else status),
        }

    def _provider_snapshot(
        self,
        provider: str,
        status: str,
        detail: str | None,
        binary_present: bool,
        session_detected: bool,
        priority: int,
        cooldown_remaining_seconds: int | None = None,
        cooldown_until: str | None = None,
        failure_count: int | None = None,
        runnable: bool | None = None,
        account_identity: str | None = None,
        account_detail: str | None = None,
        config_directory: str | None = None,
        supported_actions: list[str] | None = None,
        last_checked_at: str | None = None,
    ) -> dict[str, Any]:
        snapshot = {
            "providerName": provider,
            "status": status,
            "detail": detail,
            "binaryPresent": binary_present,
            "sessionDetected": session_detected,
            "priority": priority,
            "accountIdentity": account_identity,
            "accountDetail": account_detail,
            "configDirectory": config_directory,
            "supportedActions": supported_actions or [],
            "lastCheckedAt": last_checked_at,
        }
        if cooldown_remaining_seconds is not None:
            snapshot["cooldownRemainingSeconds"] = cooldown_remaining_seconds
        if cooldown_until is not None:
            snapshot["cooldownUntil"] = cooldown_until
        if failure_count is not None:
            snapshot["failureCount"] = failure_count
        if runnable is not None:
            snapshot["runnable"] = runnable
        return snapshot

    def _uses_fake_routing_mode(self) -> bool:
        return bool(self._fake_provider_statuses or self._fake_run_failures)

    def _compute_fake_routed_health(self, fake_provider: str, provider_order: list[str], checked_at: str) -> dict[str, Any]:
        now = time.time()
        provider_statuses: list[dict[str, Any]] = []
        available_providers: list[str] = []
        active_provider_name: str | None = None
        status_detail: str | None = None
        last_error: str | None = None

        for priority, provider in enumerate(provider_order):
            snapshot, runnable = self._fake_provider_snapshot(provider, priority, fake_provider, now, checked_at)
            provider_statuses.append(snapshot)
            if runnable:
                available_providers.append(provider)
                if active_provider_name is None:
                    active_provider_name = provider
                    status_detail = snapshot.get("detail")

        if active_provider_name is not None:
            provider_name = f"{active_provider_name}_cli_fake" if fake_provider and not self._fake_provider_statuses else "sidecar_jsonrpc_uds"
            return self._make_health(
                status="ok",
                provider_name=provider_name,
                status_detail=status_detail,
                last_error=None,
                active_provider_name=active_provider_name,
                provider_order=provider_order,
                available_providers=available_providers,
                provider_statuses=provider_statuses,
                checked_at=checked_at,
            )

        summary_status, summary_detail = self._summarize_provider_failures(provider_statuses)
        last_error = summary_detail or "No provider available"
        provider_name = f"{fake_provider}_cli_fake" if fake_provider and not self._fake_provider_statuses else "sidecar_jsonrpc_uds"
        return self._make_health(
            status=summary_status,
            provider_name=provider_name,
            status_detail=summary_detail,
            last_error=last_error,
            provider_order=provider_order,
            available_providers=available_providers,
            provider_statuses=provider_statuses,
            checked_at=checked_at,
        )

    def _compute_real_health(self, provider_order: list[str], checked_at: str) -> dict[str, Any]:
        now = time.time()
        provider_statuses: list[dict[str, Any]] = []
        available_providers: list[str] = []
        active_provider_name: str | None = None
        active_detail: str | None = None

        for priority, provider in enumerate(provider_order):
            if self._profile_directories(provider):
                snapshot, runnable = self._profile_provider_snapshot(provider, priority, now, checked_at)
            else:
                snapshot, runnable = self._real_provider_snapshot(provider, priority, now, checked_at)
            provider_statuses.append(snapshot)
            if runnable:
                available_providers.append(provider)
                if active_provider_name is None:
                    active_provider_name = provider
                    active_detail = snapshot.get("detail")

        if active_provider_name is not None:
            return self._make_health(
                status="ok",
                provider_name=f"{active_provider_name}_cli",
                status_detail=active_detail,
                last_error=None,
                active_provider_name=active_provider_name,
                provider_order=provider_order,
                available_providers=available_providers,
                provider_statuses=provider_statuses,
                checked_at=checked_at,
                runtime_health_tier="ok",
                provider_health_tier="ok",
            )

        summary_status, summary_detail = self._summarize_provider_failures(provider_statuses)
        return self._make_health(
            status=summary_status,
            provider_name="sidecar_jsonrpc_uds",
            status_detail=summary_detail,
            last_error=summary_detail,
            provider_order=provider_order,
            available_providers=available_providers,
            provider_statuses=provider_statuses,
            checked_at=checked_at,
            runtime_health_tier="ok",
            provider_health_tier="no_runnable",
        )

    def _profile_provider_snapshot(self, provider: str, priority: int, now: float, checked_at: str) -> tuple[dict[str, Any], bool]:
        preferred_accounts = self._load_preferred_accounts()
        preferred_account_name = preferred_accounts.get(provider)
        account_snapshots = [
            self._profile_account_snapshot(
                provider=provider,
                profile_path=profile_path,
                preferred_account_name=preferred_account_name,
                now=now,
                checked_at=checked_at,
                force_refresh=False,
            )
            for profile_path in self._profile_directories(provider)
        ]

        # Selection: prefer preferred-and-available, then any available, then
        # preferred-but-unavailable (for display), then first account.
        preferred_available = next(
            (a for a in account_snapshots if a.get("preferred") and a.get("available")), None
        )
        any_available = next(
            (a for a in account_snapshots if a.get("available")), None
        )

        if preferred_available:
            selected = preferred_available
        elif any_available:
            selected = any_available
        else:
            selected = next(
                (a for a in account_snapshots if a.get("preferred")),
                account_snapshots[0] if account_snapshots else None,
            )

        # Provider is runnable if ANY account is available, not just selected
        provider_runnable = any_available is not None

        if selected is None:
            return self._provider_snapshot(
                provider=provider,
                status="session_missing",
                detail="No imported accounts found for provider.",
                binary_present=shutil.which(self._provider_binary(provider)) is not None,
                session_detected=False,
                priority=priority,
                config_directory=str(self.profiles_dir() / provider),
                supported_actions=["run_auth_check", "login", "add_account", "open_config_dir"],
                last_checked_at=checked_at,
            ), False

        supported_actions = ["run_auth_check", "add_account", "open_config_dir"]
        if provider in {"claude", "codex"}:
            supported_actions.append("login")
        elif provider == "gemini":
            supported_actions.append("open_cli")
        if len(account_snapshots) > 1:
            supported_actions.append("switch_account")
        supported_actions.append("relogin")

        detail_prefix = selected.get("label") or selected.get("identity") or selected.get("accountName")
        # Provider status is "ok" when ANY account is available, not just selected
        status = "ok" if provider_runnable else ("session_expired" if selected.get("authState") == "error" else "session_missing")
        detail = selected.get("detail") or "Imported account unavailable."
        if detail_prefix:
            detail = f"{detail_prefix}: {detail}"

        snapshot = self._provider_snapshot(
            provider=provider,
            status=status,
            detail=detail,
            binary_present=bool(selected.get("binaryPresent")),
            session_detected=bool(selected.get("sessionDetected")),
            priority=priority,
            cooldown_remaining_seconds=selected.get("cooldownRemainingSeconds"),
            failure_count=1 if selected.get("lastError") else 0,
            runnable=provider_runnable,
            account_identity=self._normalize_optional_text(selected.get("identity")),
            account_detail=self._normalize_optional_text(selected.get("label") or selected.get("accountName")),
            config_directory=str(self.profiles_dir() / provider),
            supported_actions=supported_actions,
            last_checked_at=checked_at,
        )
        return snapshot, provider_runnable

    def _fake_provider_snapshot(
        self,
        provider: str,
        priority: int,
        fake_provider: str,
        now: float,
        checked_at: str,
    ) -> tuple[dict[str, Any], bool]:
        spec = self._fake_provider_statuses.get(provider)
        state = self._provider_state.setdefault(provider, {"cooldown_until": 0.0, "failure_count": 0})

        if spec is None:
            if self._fake_run_failures:
                spec = {"status": "ok", "detail": "Using deterministic fake provider routing."}
            elif fake_provider and provider == fake_provider:
                spec = {
                    "status": "ok",
                    "detail": "Using deterministic fake provider mode for memograph-advisor.",
                }
            elif self._fake_provider_statuses:
                spec = {
                    "status": "binary_missing",
                    "detail": f"{provider} CLI is not installed.",
                    "binaryPresent": False,
                    "sessionDetected": False,
                }
            else:
                spec = {"status": "ok", "detail": f"{provider} session verified."}

        status = str(spec.get("status", "ok")).strip().lower() or "ok"
        detail = spec.get("detail")
        binary_present = bool(spec.get("binaryPresent", True))
        session_detected = bool(spec.get("sessionDetected", True))
        account_identity = self._normalize_optional_text(spec.get("accountIdentity"))
        account_detail = self._normalize_optional_text(spec.get("accountDetail"))
        cooldown_seconds = self._coerce_cooldown_seconds(spec.get("cooldownSeconds"))
        existing_cooldown_remaining, existing_cooldown_until = self._cooldown_snapshot(state, now)
        config_directory = self._provider_config_dir(provider)
        supported_actions = self._provider_supported_actions(provider)

        if status == "binary_missing":
            binary_present = False
            session_detected = False
        elif status == "session_missing":
            binary_present = True
            session_detected = False
        elif status == "cooldown":
            if cooldown_seconds is None:
                cooldown_seconds = self._provider_cooldown_seconds
            with self._snapshot_lock:
                state["cooldown_until"] = max(float(state.get("cooldown_until", 0.0)), now + cooldown_seconds)
                state["last_failure_status"] = "cooldown"
                state["last_failure_detail"] = detail or f"{provider} is cooling down."
                state["failure_count"] = int(state.get("failure_count", 0)) + 1
            detail = self._with_cooldown_detail(state["last_failure_detail"], state["cooldown_until"], now)
        elif self._status_triggers_cooldown(status):
            if cooldown_seconds is None:
                cooldown_seconds = self._provider_cooldown_seconds
            with self._snapshot_lock:
                state["cooldown_until"] = max(float(state.get("cooldown_until", 0.0)), now + cooldown_seconds)
                state["last_failure_status"] = status
                state["last_failure_detail"] = detail or f"{provider} provider unavailable."
                state["failure_count"] = int(state.get("failure_count", 0)) + 1
            detail = self._with_cooldown_detail(state["last_failure_detail"], state["cooldown_until"], now)
        elif status == "ok":
            if existing_cooldown_remaining > 0:
                detail = self._with_cooldown_detail(
                    str(state.get("last_failure_detail") or detail or f"{provider} is cooling down."),
                    existing_cooldown_until,
                    now,
                )
            else:
                with self._snapshot_lock:
                    state["cooldown_until"] = 0.0
                    state["last_failure_status"] = None
                    state["last_failure_detail"] = None
                    state["failure_count"] = 0

        cooldown_remaining, cooldown_until = self._cooldown_snapshot(state, now)
        if cooldown_remaining > 0 and status == "ok":
            status = str(state.get("last_failure_status") or "cooldown")
            detail = self._with_cooldown_detail(
                str(state.get("last_failure_detail") or detail or f"{provider} is cooling down."),
                cooldown_until,
                now,
            )

        runnable = status == "ok" and cooldown_remaining == 0 and binary_present and session_detected
        snapshot = self._provider_snapshot(
            provider=provider,
            status=status,
            detail=detail,
            binary_present=binary_present,
            session_detected=session_detected,
            priority=priority,
            cooldown_remaining_seconds=cooldown_remaining if cooldown_remaining > 0 else None,
            cooldown_until=cooldown_until,
            failure_count=int(state.get("failure_count", 0)),
            runnable=runnable,
            account_identity=account_identity,
            account_detail=account_detail,
            config_directory=config_directory,
            supported_actions=supported_actions,
            last_checked_at=checked_at,
        )
        return snapshot, runnable

    def _real_provider_snapshot(self, provider: str, priority: int, now: float, checked_at: str) -> tuple[dict[str, Any], bool]:
        state = self._provider_state.setdefault(provider, {"cooldown_until": 0.0, "failure_count": 0})
        cooldown_remaining, cooldown_until = self._cooldown_snapshot(state, now)
        config_directory = self._provider_config_dir(provider)
        supported_actions = self._provider_supported_actions(provider)
        account_identity = self._normalize_optional_text(state.get("last_account_identity"))
        account_detail = self._normalize_optional_text(state.get("last_account_detail"))
        if cooldown_remaining > 0:
            status = str(state.get("last_failure_status") or "cooldown")
            detail = self._with_cooldown_detail(
                str(state.get("last_failure_detail") or f"{provider} is cooling down."),
                cooldown_until,
                now,
            )
            snapshot = self._provider_snapshot(
                provider=provider,
                status=status,
                detail=detail,
                binary_present=True,
                session_detected=True,
                priority=priority,
                cooldown_remaining_seconds=cooldown_remaining,
                cooldown_until=cooldown_until,
                failure_count=int(state.get("failure_count", 0)),
                runnable=False,
                account_identity=account_identity,
                account_detail=account_detail,
                config_directory=config_directory,
                supported_actions=supported_actions,
                last_checked_at=checked_at,
            )
            return snapshot, False

        binary_present = shutil.which(self._provider_binary(provider)) is not None
        session_detected = self._provider_has_session_marker(provider)

        if not binary_present:
            snapshot = self._provider_snapshot(
                provider=provider,
                status="binary_missing",
                detail=f"{provider} CLI is not installed.",
                binary_present=False,
                session_detected=session_detected,
                priority=priority,
                failure_count=int(state.get("failure_count", 0)),
                runnable=False,
                account_identity=account_identity,
                account_detail=account_detail,
                config_directory=config_directory,
                supported_actions=supported_actions,
                last_checked_at=checked_at,
            )
            return snapshot, False

        if not session_detected:
            detail = f"{provider} has no detectable session marker."
            snapshot = self._provider_snapshot(
                provider=provider,
                status="session_missing",
                detail=detail,
                binary_present=True,
                session_detected=False,
                priority=priority,
                failure_count=int(state.get("failure_count", 0)),
                runnable=False,
                account_identity=account_identity,
                account_detail=account_detail,
                config_directory=config_directory,
                supported_actions=supported_actions,
                last_checked_at=checked_at,
            )
            return snapshot, False

        try:
            result = self._probe_provider(provider)
        except subprocess.TimeoutExpired:
            detail = f"{provider} CLI probe timed out"
            self._record_provider_failure_locked(
                provider=provider,
                status="timeout",
                detail=detail,
                now=now,
            )
            cooldown_remaining, cooldown_until = self._cooldown_snapshot(state, now)
            snapshot = self._provider_snapshot(
                provider=provider,
                status="timeout",
                detail=self._with_cooldown_detail(detail, cooldown_until, now),
                binary_present=True,
                session_detected=True,
                priority=priority,
                cooldown_remaining_seconds=cooldown_remaining if cooldown_remaining > 0 else None,
                cooldown_until=cooldown_until,
                failure_count=int(state.get("failure_count", 0)),
                runnable=False,
                account_identity=account_identity,
                account_detail=account_detail,
                config_directory=config_directory,
                supported_actions=supported_actions,
                last_checked_at=checked_at,
            )
            return snapshot, False
        except Exception as exc:  # pragma: no cover - defensive
            detail = f"{provider} probe failed: {exc}"
            self._record_provider_failure_locked(
                provider=provider,
                status="unavailable",
                detail=detail,
                now=now,
            )
            cooldown_remaining, cooldown_until = self._cooldown_snapshot(state, now)
            snapshot = self._provider_snapshot(
                provider=provider,
                status="unavailable",
                detail=self._with_cooldown_detail(detail, cooldown_until, now),
                binary_present=True,
                session_detected=True,
                priority=priority,
                cooldown_remaining_seconds=cooldown_remaining if cooldown_remaining > 0 else None,
                cooldown_until=cooldown_until,
                failure_count=int(state.get("failure_count", 0)),
                runnable=False,
                account_identity=account_identity,
                account_detail=account_detail,
                config_directory=config_directory,
                supported_actions=supported_actions,
                last_checked_at=checked_at,
            )
            return snapshot, False

        status = str(result.get("status") or "unavailable").strip().lower() or "unavailable"
        detail = str(result.get("detail") or f"{provider} provider unavailable.")
        result_account_identity = self._normalize_optional_text(result.get("accountIdentity"))
        result_account_detail = self._normalize_optional_text(result.get("accountDetail"))
        if status == "ok":
            with self._snapshot_lock:
                state["cooldown_until"] = 0.0
                state["last_failure_status"] = None
                state["last_failure_detail"] = None
                state["failure_count"] = 0
                state["last_account_identity"] = result_account_identity
                state["last_account_detail"] = result_account_detail
            snapshot = self._provider_snapshot(
                provider=provider,
                status="ok",
                detail=detail,
                binary_present=True,
                session_detected=True,
                priority=priority,
                runnable=True,
                account_identity=result_account_identity,
                account_detail=result_account_detail,
                config_directory=config_directory,
                supported_actions=supported_actions,
                last_checked_at=checked_at,
            )
            return snapshot, True

        self._record_provider_failure_locked(
            provider=provider,
            status=status,
            detail=detail,
            now=now,
        )
        cooldown_remaining, cooldown_until = self._cooldown_snapshot(state, now)
        snapshot = self._provider_snapshot(
            provider=provider,
            status=status,
            detail=self._with_cooldown_detail(detail, cooldown_until, now),
            binary_present=True,
            session_detected=True,
            priority=priority,
            cooldown_remaining_seconds=cooldown_remaining if cooldown_remaining > 0 else None,
            cooldown_until=cooldown_until,
            failure_count=int(state.get("failure_count", 0)),
            runnable=False,
            account_identity=result_account_identity or account_identity,
            account_detail=result_account_detail or account_detail,
            config_directory=config_directory,
            supported_actions=supported_actions,
            last_checked_at=checked_at,
        )
        return snapshot, False

    def _summarize_provider_failures(self, provider_statuses: list[dict[str, Any]]) -> tuple[str, str]:
        if not provider_statuses:
            return "no_provider", "No provider available"

        for status_name in ["session_expired", "timeout", "unavailable", "cooldown", "session_missing", "binary_missing"]:
            for diagnostic in provider_statuses:
                if diagnostic.get("status") == status_name:
                    detail = str(diagnostic.get("detail") or status_name.replace("_", " "))
                    return status_name if status_name != "binary_missing" else "no_provider", detail

        for diagnostic in provider_statuses:
            detail = str(diagnostic.get("detail") or "No provider available")
            return str(diagnostic.get("status") or "no_provider"), detail
        return "no_provider", "No provider available"

    def _status_triggers_cooldown(self, status: str) -> bool:
        return status in {"session_expired", "timeout", "unavailable", "cooldown"}

    def _account_failure_is_retryable(self, status: str | None) -> bool:
        return str(status or "").strip().lower() in RETRYABLE_ACCOUNT_FAILURE_STATUSES

    def _account_failure_is_terminal(self, status: str | None) -> bool:
        normalized = str(status or "").strip().lower()
        if not normalized:
            return False
        return normalized in TERMINAL_ACCOUNT_FAILURE_STATUSES

    def _cooldown_snapshot(self, state: dict[str, Any], now: float) -> tuple[int, str | None]:
        cooldown_until = float(state.get("cooldown_until", 0.0) or 0.0)
        if cooldown_until <= now:
            if cooldown_until:
                state["cooldown_until"] = 0.0
            return 0, None
        remaining = max(1, int(math.ceil(cooldown_until - now)))
        return remaining, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(cooldown_until))

    def _with_cooldown_detail(self, detail: str, cooldown_until: str | None, now: float) -> str:
        if not cooldown_until:
            return detail
        try:
            parsed = time.strptime(cooldown_until, "%Y-%m-%dT%H:%M:%SZ")
            remaining = max(1, int(math.ceil(calendar.timegm(parsed) - now)))
        except Exception:
            return f"{detail} (cooldown until {cooldown_until})"
        return f"{detail} (cooldown {remaining}s remaining until {cooldown_until})"

    def _health_cache_ttl_seconds(self, health: dict[str, Any], now: float) -> float:
        statuses = health.get("providerStatuses") or []
        if any(
            isinstance(status, dict) and int(status.get("cooldownRemainingSeconds") or 0) > 0
            for status in statuses
        ):
            return 2.0
        return self._cache_ttl_seconds

    def _record_provider_failure_locked(
        self,
        provider: str,
        status: str,
        detail: str,
        now: float,
        cooldown_seconds: int | None = None,
    ) -> None:
        with self._snapshot_lock:
            state = self._provider_state.setdefault(provider, {"cooldown_until": 0.0, "failure_count": 0})
            cooldown_seconds = cooldown_seconds or self._provider_cooldown_seconds
            state["cooldown_until"] = max(float(state.get("cooldown_until", 0.0)), now + cooldown_seconds)
            state["last_failure_status"] = status
            state["last_failure_detail"] = detail
            state["failure_count"] = int(state.get("failure_count", 0)) + 1
            self._invalidate_cache()

    def _record_account_failure_locked(
        self,
        state_key: str,
        status: str,
        detail: str,
        now: float,
        cooldown_seconds: int | None = None,
    ) -> None:
        with self._snapshot_lock:
            state = self._account_state.setdefault(state_key, {"cooldown_until": 0.0, "failure_count": 0, "requests_made": 0})
            cooldown_seconds = cooldown_seconds or self._provider_cooldown_seconds
            state["cooldown_until"] = max(float(state.get("cooldown_until", 0.0)), now + cooldown_seconds)
            state["last_failure_status"] = status
            state["last_failure_detail"] = detail
            state["failure_count"] = int(state.get("failure_count", 0)) + 1
            state["last_checked_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
            self._invalidate_cache()

    def _invalidate_accounts_cache_locked(self) -> None:
        self._cached_accounts = None
        self._accounts_checked_at = 0.0

    def _invalidate_cache(self) -> None:
        self._cached_health = None
        self._checked_at = 0.0
        self._cached_accounts = None
        self._accounts_checked_at = 0.0

    def _read_int_env(self, names: list[str], default: int, minimum: int, maximum: int) -> int:
        for name in names:
            raw = os.getenv(name, "").strip()
            if not raw:
                continue
            try:
                value = int(raw)
            except ValueError:
                continue
            return max(minimum, min(maximum, value))
        return max(minimum, min(maximum, default))

    def _coerce_cooldown_seconds(self, raw: Any) -> int | None:
        if raw is None:
            return None
        if isinstance(raw, bool):
            return None
        if isinstance(raw, (int, float)):
            value = int(raw)
            return max(1, value)
        try:
            value = int(str(raw).strip())
        except (TypeError, ValueError):
            return None
        return max(1, value)

    def _json_or_none(self, raw: str) -> Any:
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None

    def _parse_fake_provider_statuses(self, raw: str) -> dict[str, dict[str, Any]]:
        if not raw:
            return {}
        parsed = self._json_or_none(raw)
        statuses: dict[str, dict[str, Any]] = {}
        if isinstance(parsed, dict):
            for provider, value in parsed.items():
                normalized = self._normalize_status_spec(value, str(provider))
                if normalized is not None:
                    statuses[str(provider).strip().lower()] = normalized
            return statuses
        if isinstance(parsed, list):
            for item in parsed:
                provider = self._extract_provider_name(item)
                normalized = self._normalize_status_spec(item, provider)
                if provider and normalized is not None:
                    statuses[provider] = normalized
            return statuses

        for token in re.split(r"[,\n;|]+", raw):
            token = token.strip()
            if not token:
                continue
            if "=" in token:
                provider, value = token.split("=", 1)
            elif ":" in token:
                provider, value = token.split(":", 1)
            else:
                continue
            provider = provider.strip().lower()
            if not provider:
                continue
            normalized = self._normalize_status_spec(value.strip(), provider)
            if normalized is not None:
                statuses[provider] = normalized
        return statuses

    def _parse_fake_run_failures(self, raw: str) -> dict[str, list[dict[str, Any]]]:
        if not raw:
            return {}
        parsed = self._json_or_none(raw)
        failures: dict[str, list[dict[str, Any]]] = {}
        if isinstance(parsed, dict):
            for provider, value in parsed.items():
                provider_name = str(provider).strip().lower()
                if not provider_name:
                    continue
                for spec in self._normalize_failure_specs(value, provider_name):
                    failures.setdefault(provider_name, []).append(spec)
            return failures
        if isinstance(parsed, list):
            for item in parsed:
                provider = self._extract_provider_name(item)
                if not provider:
                    continue
                for spec in self._normalize_failure_specs(item, provider):
                    failures.setdefault(provider, []).append(spec)
            return failures

        for token in re.split(r"[,\n;|]+", raw):
            token = token.strip()
            if not token:
                continue
            if "=" in token:
                provider, value = token.split("=", 1)
            elif ":" in token:
                provider, value = token.split(":", 1)
            else:
                continue
            provider = provider.strip().lower()
            if not provider:
                continue
            for spec in self._normalize_failure_specs(value.strip(), provider):
                failures.setdefault(provider, []).append(spec)
        return failures

    def _normalize_status_spec(self, value: Any, provider: str) -> dict[str, Any] | None:
        if isinstance(value, dict):
            status = str(value.get("status") or value.get("state") or "ok").strip().lower() or "ok"
            detail = value.get("detail") or value.get("message")
            spec: dict[str, Any] = {"status": status}
            if detail is not None:
                spec["detail"] = str(detail)
            account_identity = self._normalize_optional_text(value.get("accountIdentity") or value.get("identity"))
            if account_identity is not None:
                spec["accountIdentity"] = account_identity
            account_detail = self._normalize_optional_text(value.get("accountDetail") or value.get("identityDetail"))
            if account_detail is not None:
                spec["accountDetail"] = account_detail
            if "binaryPresent" in value:
                spec["binaryPresent"] = bool(value.get("binaryPresent"))
            if "sessionDetected" in value:
                spec["sessionDetected"] = bool(value.get("sessionDetected"))
            cooldown_seconds = self._coerce_cooldown_seconds(value.get("cooldownSeconds") or value.get("cooldown"))
            if cooldown_seconds is not None:
                spec["cooldownSeconds"] = cooldown_seconds
            return spec
        if isinstance(value, str):
            raw = value.strip()
            if not raw:
                return {"status": "ok"}
            status, detail = self._split_spec_string(raw)
            spec = {"status": status}
            if detail is not None:
                spec["detail"] = detail
            if status == "cooldown":
                cooldown_seconds = self._coerce_cooldown_seconds(detail)
                if cooldown_seconds is not None:
                    spec["cooldownSeconds"] = cooldown_seconds
                    spec.pop("detail", None)
            return spec
        if value is None:
            return {"status": "ok"}
        return {"status": str(value).strip().lower() or "ok"}

    def _normalize_failure_specs(self, value: Any, provider: str) -> list[dict[str, Any]]:
        if isinstance(value, list):
            specs: list[dict[str, Any]] = []
            for item in value:
                specs.extend(self._normalize_failure_specs(item, provider))
            return specs
        if isinstance(value, dict):
            spec: dict[str, Any] = {}
            status = str(value.get("status") or value.get("state") or "unavailable").strip().lower() or "unavailable"
            spec["status"] = status
            detail = value.get("detail") or value.get("message")
            if detail is not None:
                spec["detail"] = str(detail)
            cooldown_seconds = self._coerce_cooldown_seconds(value.get("cooldownSeconds") or value.get("cooldown"))
            if cooldown_seconds is not None:
                spec["cooldownSeconds"] = cooldown_seconds
            return [spec]
        if isinstance(value, str):
            raw = value.strip()
            if not raw:
                return [{"status": "unavailable"}]
            status, detail = self._split_spec_string(raw)
            spec = {"status": status}
            if detail is not None:
                spec["detail"] = detail
            if status == "cooldown":
                cooldown_seconds = self._coerce_cooldown_seconds(detail)
                if cooldown_seconds is not None:
                    spec["cooldownSeconds"] = cooldown_seconds
                    spec.pop("detail", None)
            return [spec]
        if value is None:
            return [{"status": "unavailable"}]
        return [{"status": str(value).strip().lower() or "unavailable"}]

    def _split_spec_string(self, raw: str) -> tuple[str, str | None]:
        if ":" not in raw:
            return raw.strip().lower(), None
        status, detail = raw.split(":", 1)
        return status.strip().lower(), detail.strip() or None

    def _extract_provider_name(self, value: Any) -> str:
        if not isinstance(value, dict):
            return ""
        provider = value.get("provider") or value.get("providerName") or value.get("name")
        return str(provider).strip().lower() if provider else ""

    def _select_provider_attempt_budget(self) -> int:
        return max(1, self._run_attempt_budget)

    def _consume_fake_run_failure(self, provider: str) -> dict[str, Any] | None:
        provider = provider.strip().lower()
        failures = self._fake_run_failures.get(provider)
        if not failures:
            return None
        failure = failures.pop(0)
        if not failures:
            self._fake_run_failures.pop(provider, None)
        return failure

    def _provider_order(self) -> list[str]:
        raw = os.getenv("MEMOGRAPH_ADVISOR_PROVIDER_ORDER", "").strip()
        if raw:
            values = [item.strip().lower() for item in raw.split(",") if item.strip()]
            if values:
                return values
        return ["claude", "gemini", "codex"]

    def _provider_binary(self, provider: str) -> str:
        return provider

    def _provider_config_dir(self, provider: str) -> str | None:
        selected_profile = self._selected_profile_root(provider)
        if selected_profile is not None:
            if provider == "codex":
                return str(selected_profile)
            if provider == "claude":
                return str(selected_profile / "home" / ".claude")
            if provider == "gemini":
                primary = selected_profile / "home" / ".gemini"
                xdg = selected_profile / "home" / ".config" / "gemini"
                if primary.exists():
                    return str(primary)
                if xdg.exists():
                    return str(xdg)
                return str(primary)

        home = self.source_home()
        if provider == "codex":
            return str(home / ".codex")
        if provider == "claude":
            return str(home / ".claude")
        if provider == "gemini":
            primary = home / ".gemini"
            xdg = home / ".config" / "gemini"
            if primary.exists():
                return str(primary)
            if xdg.exists():
                return str(xdg)
            return str(primary)
        return None

    def _provider_supported_actions(self, provider: str) -> list[str]:
        if provider == "claude":
            return ["run_auth_check", "login", "relogin", "logout", "add_account", "switch_account", "open_config_dir"]
        if provider == "codex":
            return ["run_auth_check", "login", "relogin", "add_account", "switch_account", "open_config_dir"]
        if provider == "gemini":
            return ["run_auth_check", "open_cli", "add_account", "switch_account", "open_config_dir"]
        return ["run_auth_check"]

    def _normalize_optional_text(self, value: Any) -> str | None:
        if value is None:
            return None
        text = str(value).strip()
        return text or None

    def _provider_has_session_marker(self, provider: str) -> bool:
        selected_profile = self._selected_profile_root(provider)
        if selected_profile is not None:
            if provider == "codex":
                return (selected_profile / "auth.json").exists() or (selected_profile / "config.toml").exists()
            if provider == "claude":
                return (selected_profile / "home" / ".claude").exists()
            if provider == "gemini":
                return (selected_profile / "home" / ".gemini").exists() or (selected_profile / "home" / ".config" / "gemini").exists()

        home = self.source_home()
        if provider == "codex":
            return (home / ".codex" / "auth.json").exists() or (home / ".codex" / "config.toml").exists()
        if provider == "claude":
            return (home / ".claude").exists()
        if provider == "gemini":
            return (home / ".gemini").exists() or (home / ".config" / "gemini").exists()
        return False

    def _probe_provider(self, provider: str, env: dict[str, str] | None = None) -> dict[str, str]:
        command = self._probe_command(provider)
        selected_profile_name = self._selected_profile_name(provider)
        selected_profile = self._selected_profile_root(provider)
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=self.probe_timeout_seconds,
            env=env or self._provider_env(provider),
        )

        stdout = completed.stdout.strip()
        stderr = completed.stderr.strip()
        combined = "\n".join(part for part in [stdout, stderr] if part).strip()

        if provider == "codex":
            if completed.returncode == 0 and "logged in" in combined.lower():
                identity = None
                lower = combined.lower()
                if "using " in lower:
                    identity = combined[lower.index("using ") + len("using "):].strip().rstrip(".")
                identity = identity or self._profile_identity_hint(provider, selected_profile)
                account_detail = combined or "Codex login verified."
                if selected_profile_name:
                    account_detail = f"{selected_profile_name} · {account_detail}"
                return {
                    "status": "ok",
                    "detail": combined or "Codex login verified.",
                    "accountIdentity": identity or "ChatGPT",
                    "accountDetail": account_detail,
                }
            return self._provider_failure(provider, combined or "Codex login status failed.")

        if provider == "claude":
            try:
                payload = json.loads(stdout) if stdout else {}
            except json.JSONDecodeError:
                payload = {}
            if completed.returncode == 0 and isinstance(payload, dict) and payload.get("loggedIn") is True:
                email = str(payload.get("email", "")).strip()
                subscription = str(payload.get("subscriptionType", "")).strip()
                auth_method = str(payload.get("authMethod", "")).strip()
                org_name = str(payload.get("orgName", "")).strip()
                detail_parts = [part for part in [subscription, auth_method, org_name] if part]
                account_detail = " · ".join(detail_parts) if detail_parts else "Claude session verified."
                if selected_profile_name:
                    account_detail = f"{selected_profile_name} · {account_detail}"
                return {
                    "status": "ok",
                    "detail": email or "Claude session verified.",
                    "accountIdentity": email or self._profile_identity_hint(provider, selected_profile) or "Claude account",
                    "accountDetail": account_detail,
                }
            return self._provider_failure(provider, combined or "Claude auth status failed.")

        if provider == "gemini":
            payload = self._extract_json_payload(stdout)
            if isinstance(payload, dict) and str(payload.get("response", "")).strip().upper() == "OK":
                account_detail = "Gemini CLI credentials verified."
                if selected_profile_name:
                    account_detail = f"{selected_profile_name} · {account_detail}"
                return {
                    "status": "ok",
                    "detail": "Gemini session verified.",
                    "accountIdentity": self._profile_identity_hint(provider, selected_profile),
                    "accountDetail": account_detail,
                }
            if completed.returncode == 0 and isinstance(payload, dict) and not payload.get("error"):
                account_detail = "Gemini CLI credentials verified."
                if selected_profile_name:
                    account_detail = f"{selected_profile_name} · {account_detail}"
                return {
                    "status": "ok",
                    "detail": "Gemini session verified.",
                    "accountIdentity": self._profile_identity_hint(provider, selected_profile),
                    "accountDetail": account_detail,
                }
            if isinstance(payload, dict) and isinstance(payload.get("error"), dict):
                message = str(payload["error"].get("message", "")).strip()
            else:
                message = combined or "Gemini auth probe failed."
            return self._provider_failure(provider, message)

        return {"status": "unavailable", "detail": f"Unsupported provider: {provider}"}

    def _probe_command(self, provider: str) -> list[str]:
        if provider == "codex":
            return ["codex", "login", "status"]
        if provider == "claude":
            return ["claude", "auth", "status"]
        if provider == "gemini":
            return [
                "gemini",
                "-p",
                "Reply with exactly OK.",
                "--output-format",
                "json",
                "--approval-mode",
                "yolo",
            ]
        raise ValueError(f"Unsupported provider: {provider}")

    def _provider_failure(self, provider: str, message: str) -> dict[str, str]:
        lowered = message.lower()
        if any(token in lowered for token in ["not logged", "login", "auth", "expired", "reauth", "credential"]):
            return {"status": "session_expired", "detail": f"{provider}: {message}"}
        return {"status": "unavailable", "detail": f"{provider}: {message}"}

    def _selected_profile_name(self, provider: str) -> str | None:
        preferred_account = self._load_preferred_accounts().get(provider)
        if preferred_account:
            return preferred_account
        env_value = os.getenv(f"MEMOGRAPH_ADVISOR_PROFILE_{provider.upper()}", "").strip()
        return env_value or None

    def _selected_profile_root(self, provider: str) -> Path | None:
        account_name = self._selected_profile_name(provider)
        if not account_name:
            return None
        profile_root = self._profiles_dir / provider / account_name
        return profile_root if profile_root.exists() else None

    def _provider_env(self, provider: str) -> dict[str, str]:
        env = os.environ.copy()
        profile_root = self._selected_profile_root(provider)
        if profile_root is None:
            return env

        if provider == "codex":
            env["CODEX_HOME"] = str(profile_root)
            return env

        env["HOME"] = str(profile_root / "home")
        env["PATH"] = os.environ.get("PATH", "")
        if provider == "gemini":
            nvm_dir = self.source_home() / ".nvm"
            if nvm_dir.exists():
                env["NVM_DIR"] = str(nvm_dir)
        return env

    def _read_json_file(self, path: Path) -> Any:
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None

    def _extract_json_payload(self, text: str) -> Any:
        stripped = (text or "").strip()
        if not stripped:
            return None
        try:
            return json.loads(stripped)
        except json.JSONDecodeError:
            pass
        # Gemini CLI may emit non-JSON warnings to stdout before the JSON
        # payload (e.g. "MCP issues detected. ...{").  Scan for the first
        # top-level '{' and try to parse from that offset.
        brace_index = stripped.find("{")
        if brace_index > 0:
            candidate = stripped[brace_index:]
            try:
                return json.loads(candidate)
            except json.JSONDecodeError:
                pass
        # Fall back to line-by-line parsing for other edge cases.
        for line in stripped.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
        return None


@dataclass(frozen=True)
class ExecutionBinding:
    """Immutable binding from routing to execution — ensures handlers use the routed provider."""
    provider_name: str
    account_name: str | None
    route_reason: str  # "recipe_primary" | "recipe_secondary" | "provider_fallback" | "only_available"
    attempt_index: int


@dataclass(frozen=True)
class ProviderCLIResult:
    status: str
    detail: str
    output: str | None = None
    account_name: str | None = None
    returncode: int | None = None
    stdout: str | None = None
    stderr: str | None = None

    @property
    def ok(self) -> bool:
        return self.status == "ok"


class AdvisoryRuntime:
    def __init__(self, probe_timeout_seconds: int) -> None:
        self._logger = logging.getLogger("memograph_advisor")
        self.provider_diagnostics = ProviderDiagnostics(probe_timeout_seconds=probe_timeout_seconds)
        self._cancelled_runs: set[str] = set()
        self._lock = threading.Lock()
        self._recipe_routing: dict[str, list[str]] = {
            "continuity_resume":   ["claude", "gemini", "codex"],
            "thread_maintenance":  ["claude", "gemini", "codex"],
            "writing_seed":        ["claude", "codex", "gemini"],
            "tweet_from_thread":   ["claude", "codex", "gemini"],
            "research_direction":  ["gemini", "claude", "codex"],
            "weekly_reflection":   ["gemini", "claude", "codex"],
            "focus_reflection":    ["claude", "gemini", "codex"],
            "social_signal":       ["claude", "codex", "gemini"],
            "health_pulse":        ["claude", "gemini", "codex"],
            "decision_review":     ["claude", "gemini", "codex"],
            "life_admin_review":   ["claude", "gemini", "codex"],
        }

    def health(self, force_refresh: bool = False) -> dict[str, Any]:
        return self.provider_diagnostics.health(force_refresh=force_refresh)

    def accounts(self, force_refresh: bool = False) -> dict[str, Any]:
        return self.provider_diagnostics.accounts(force_refresh=force_refresh)

    def _should_use_provider_cli(self, provider_name: str | None) -> bool:
        if not provider_name:
            return False
        if os.getenv("MEMOGRAPH_ADVISOR_FAKE_PROVIDER", "").strip():
            return False
        if self.provider_diagnostics._uses_fake_routing_mode():
            return False
        return True

    def auth_check(
        self,
        provider_name: str,
        account_name: str | None = None,
        force_refresh: bool = False,
    ) -> dict[str, Any]:
        return self.check_provider_auth(
            provider_name,
            account_name=account_name,
            force_refresh=force_refresh,
        )

    def cancel_run(self, run_id: str) -> dict[str, Any]:
        with self._lock:
            self._cancelled_runs.add(run_id)
        return {}

    def open_login(self, provider_name: str) -> dict[str, Any]:
        provider = provider_name.strip().lower()
        if provider not in VALID_PROVIDERS:
            raise JsonRPCMethodError(-32602, f"Unknown provider: {provider_name}")
        command = open_login_terminal(provider, cwd=self.provider_diagnostics.source_home())
        return self._account_action_result(
            provider=provider,
            account_name=None,
            command=command,
            message=f"Opened {provider} login flow in Terminal. Complete auth there, then import the current session.",
            force_refresh=False,
        )

    def import_current_session(self, provider_name: str, account_name: str | None = None) -> dict[str, Any]:
        provider = provider_name.strip().lower()
        if provider not in VALID_PROVIDERS:
            raise JsonRPCMethodError(-32602, f"Unknown provider: {provider_name}")
        try:
            imported_name = import_current_session(
                provider,
                self.provider_diagnostics.profiles_dir(),
                home=self.provider_diagnostics.source_home(),
                account_name=account_name,
            )
        except (FileNotFoundError, ValueError) as exc:
            raise JsonRPCMethodError(-32020, str(exc)) from exc

        preferred_accounts = self.provider_diagnostics._load_preferred_accounts()
        preferred_accounts.setdefault(provider, imported_name)
        self.provider_diagnostics._save_preferred_accounts(preferred_accounts)
        with self.provider_diagnostics._snapshot_lock:
            self.provider_diagnostics._invalidate_cache()

        return self._account_action_result(
            provider=provider,
            account_name=imported_name,
            command=None,
            message=f"Imported current {provider} session as {imported_name}.",
            force_refresh=True,
        )

    def reauthorize(self, provider_name: str, account_name: str) -> dict[str, Any]:
        provider = provider_name.strip().lower()
        if provider not in VALID_PROVIDERS:
            raise JsonRPCMethodError(-32602, f"Unknown provider: {provider_name}")
        try:
            profile_path = self.provider_diagnostics._profile_directory(provider, account_name)
        except FileNotFoundError as exc:
            raise JsonRPCMethodError(-32021, str(exc)) from exc
        command = open_login_terminal_for_profile(
            provider,
            profile_path,
            cwd=self.provider_diagnostics.source_home(),
            real_home=self.provider_diagnostics.source_home(),
        )
        return self._account_action_result(
            provider=provider,
            account_name=account_name,
            command=command,
            message=f"Opened Terminal for {provider}/{account_name}. Finish login there, then run auth check.",
            force_refresh=False,
        )

    def set_account_label(self, provider_name: str, account_name: str, label: str) -> dict[str, Any]:
        provider = provider_name.strip().lower()
        if provider not in VALID_PROVIDERS:
            raise JsonRPCMethodError(-32602, f"Unknown provider: {provider_name}")
        try:
            self.provider_diagnostics._profile_directory(provider, account_name)
        except FileNotFoundError as exc:
            raise JsonRPCMethodError(-32021, str(exc)) from exc
        normalized = set_account_label(self.provider_diagnostics.profiles_dir(), provider, account_name, label)
        with self.provider_diagnostics._snapshot_lock:
            self.provider_diagnostics._invalidate_cache()
        message = (
            f"Updated label for {provider}/{account_name}."
            if normalized
            else f"Cleared label for {provider}/{account_name}."
        )
        return self._account_action_result(
            provider=provider,
            account_name=account_name,
            command=None,
            message=message,
            force_refresh=False,
        )

    def set_preferred_account(self, provider_name: str, account_name: str) -> dict[str, Any]:
        provider = provider_name.strip().lower()
        if provider not in VALID_PROVIDERS:
            raise JsonRPCMethodError(-32602, f"Unknown provider: {provider_name}")
        try:
            self.provider_diagnostics._profile_directory(provider, account_name)
        except FileNotFoundError as exc:
            raise JsonRPCMethodError(-32021, str(exc)) from exc
        self.provider_diagnostics._set_preferred_account_locked(provider, account_name)
        return self._account_action_result(
            provider=provider,
            account_name=account_name,
            command=None,
            message=f"{provider}/{account_name} is now the preferred account.",
            force_refresh=False,
        )

    def _account_action_result(
        self,
        provider: str,
        account_name: str | None,
        command: str | None,
        message: str,
        force_refresh: bool,
    ) -> dict[str, Any]:
        return {
            "status": "ok",
            "providerName": provider,
            "accountName": account_name,
            "command": command,
            "message": message,
            "snapshot": self.provider_diagnostics.accounts(force_refresh=force_refresh),
        }

    def check_provider_auth(self, provider_name: str, account_name: str | None = None, force_refresh: bool = False) -> dict[str, Any]:
        provider = provider_name.strip().lower()
        if provider not in VALID_PROVIDERS:
            raise JsonRPCMethodError(-32602, f"Unknown provider: {provider_name}")

        now = time.time()
        checked_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
        target_account = account_name.strip() if account_name else None
        if not target_account:
            target_account = self._select_account_for_provider(provider)

        if target_account:
            try:
                profile_path = self.provider_diagnostics._profile_directory(provider, target_account)
            except FileNotFoundError:
                return {
                    "providerName": provider,
                    "accountName": target_account,
                    "verified": False,
                    "status": "account_not_found",
                    "detail": f"Unknown {provider} account: {target_account}",
                    "checkedAt": checked_at,
                }

            preferred_accounts = self.provider_diagnostics._load_preferred_accounts()
            snapshot = self.provider_diagnostics._profile_account_snapshot(
                provider=provider,
                profile_path=profile_path,
                preferred_account_name=preferred_accounts.get(provider),
                now=now,
                checked_at=checked_at,
                force_refresh=force_refresh,
            )
            status = self._account_auth_status_from_snapshot(provider, snapshot)
            verified = status == "ok"
            detail = str(snapshot.get("detail") or snapshot.get("lastError") or status).strip()
            return {
                "providerName": provider,
                "accountName": snapshot.get("accountName") or target_account,
                "verified": verified,
                "status": status,
                "detail": detail,
                "checkedAt": checked_at,
                "identity": self.provider_diagnostics._normalize_optional_text(snapshot.get("identity")),
            }

        try:
            probe = self.provider_diagnostics._probe_provider(provider)
        except subprocess.TimeoutExpired:
            return {
                "providerName": provider,
                "accountName": None,
                "verified": False,
                "status": "timeout",
                "detail": f"{provider} auth probe timed out.",
                "checkedAt": checked_at,
            }
        except Exception as exc:
            return {
                "providerName": provider,
                "accountName": None,
                "verified": False,
                "status": "unavailable",
                "detail": f"{provider} auth probe failed: {exc}",
                "checkedAt": checked_at,
            }

        status = str(probe.get("status") or "unavailable").strip().lower() or "unavailable"
        verified = status == "ok"
        account_name_result = target_account or self.provider_diagnostics._selected_profile_name(provider)
        return {
            "providerName": provider,
            "accountName": account_name_result,
            "verified": verified,
            "status": "ok" if verified else status,
            "detail": str(probe.get("detail") or probe.get("lastError") or status).strip(),
            "checkedAt": checked_at,
            "identity": self.provider_diagnostics._normalize_optional_text(probe.get("accountIdentity")),
        }

    def _candidate_account_sort_key(
        self,
        account_name: str,
        state: dict[str, Any],
        preferred_account_name: str | None,
    ) -> tuple[int, int, int, int, str]:
        requests_made = int(state.get("requests_made", 0) or 0)
        failure_count = int(state.get("failure_count", 0) or 0)
        last_used_at = int(state.get("last_used_at", 0) or 0)
        preferred_bias = 0 if preferred_account_name and account_name == preferred_account_name else 1
        return (requests_made, failure_count, last_used_at, preferred_bias, account_name)

    def _candidate_accounts_for_provider(self, provider: str, preferred_account_name: str | None = None) -> list[str]:
        profiles = self.provider_diagnostics._profile_directories(provider)
        if not profiles:
            selected = preferred_account_name or self.provider_diagnostics._selected_profile_name(provider)
            return [selected] if selected else []

        preferred = preferred_account_name or self.provider_diagnostics._load_preferred_accounts().get(provider)
        binary_present = shutil.which(self.provider_diagnostics._provider_binary(provider)) is not None
        now = time.time()
        candidates: list[tuple[tuple[int, int, int, int, str], str]] = []

        with self.provider_diagnostics._snapshot_lock:
            for profile_path in profiles:
                account_name = profile_path.name
                if not binary_present or not self.provider_diagnostics._profile_has_session_marker(provider, profile_path):
                    continue

                state_key = self.provider_diagnostics._profile_account_key(provider, account_name)
                state = self.provider_diagnostics._account_state.get(state_key, {})
                if now < float(state.get("cooldown_until", 0.0)):
                    continue

                failure_status = str(state.get("last_failure_status") or "").strip().lower()
                if failure_status and not self.provider_diagnostics._account_failure_is_retryable(failure_status):
                    continue

                sort_key = self._candidate_account_sort_key(
                    account_name,
                    state,
                    preferred_account_name=preferred,
                )
                candidates.append((sort_key, account_name))

        candidates.sort(key=lambda item: item[0])
        return [account_name for _, account_name in candidates]

    def _run_provider_cli_with_failover(
        self,
        provider: str,
        prompt: str,
        account_name: str | None = None,
        timeout_seconds: int = 60,
        max_output_length: int = 8000,
        recipe_name: str | None = None,
    ) -> ProviderCLIResult:
        fake_provider = os.getenv("MEMOGRAPH_ADVISOR_FAKE_PROVIDER", "").strip().lower()
        if fake_provider or self.provider_diagnostics._uses_fake_routing_mode():
            return ProviderCLIResult(
                status="ok",
                detail=f"{provider} fake routing mode skipped live CLI invocation.",
                output=None,
                account_name=account_name or self.provider_diagnostics._selected_profile_name(provider) or "acc1",
            )

        candidates = self._candidate_accounts_for_provider(provider, preferred_account_name=account_name)
        if not candidates:
            profiles_exist = bool(self.provider_diagnostics._profile_directories(provider))
            if profiles_exist and account_name is None:
                return ProviderCLIResult(
                    status="no_runnable",
                    detail=f"No runnable {provider} accounts available.",
                    account_name=None,
                )
            elif account_name is not None:
                candidates = [account_name]
            else:
                candidates = [None]

        last_result: ProviderCLIResult | None = None
        for candidate in candidates:
            result = self._call_provider_cli(
                provider,
                prompt,
                account_name=candidate,
                timeout_seconds=timeout_seconds,
                max_output_length=max_output_length,
            )
            last_result = result
            if result.ok:
                recorded_at = time.time()
                self.provider_diagnostics._record_provider_success_locked(provider, now=recorded_at)
                self.provider_diagnostics._record_account_use_locked(
                    provider,
                    result.account_name or candidate,
                    now=recorded_at,
                )
                return result

            if candidate:
                if result.status not in {"binary_missing", "unsupported"}:
                    state_key = self.provider_diagnostics._profile_account_key(provider, candidate)
                    self.provider_diagnostics._record_account_failure_locked(
                        state_key=state_key,
                        status=result.status,
                        detail=result.detail,
                        now=time.time(),
                    )

            if result.status in {"binary_missing", "unsupported"}:
                break

        if last_result is None:
            last_result = ProviderCLIResult(
                status="unavailable",
                detail=f"{provider} CLI call did not start.",
                account_name=account_name,
            )

        self.provider_diagnostics._record_provider_failure_locked(
            provider=provider,
            status=last_result.status,
            detail=last_result.detail,
            now=time.time(),
        )
        if recipe_name:
            self._logger.info(
                "provider_cli_exhausted recipe=%s provider=%s status=%s account=%s detail=%s",
                recipe_name,
                provider,
                last_result.status,
                last_result.account_name or account_name,
                last_result.detail,
            )
        return last_result

    def _call_provider_cli(
        self,
        provider: str,
        prompt: str,
        account_name: str | None = None,
        timeout_seconds: int = 60,
        max_output_length: int = 8000,
    ) -> ProviderCLIResult:
        binary = shutil.which(self.provider_diagnostics._provider_binary(provider))
        if not binary:
            return ProviderCLIResult(
                status="binary_missing",
                detail=f"{provider} CLI is not installed.",
                account_name=account_name,
            )

        if provider == "claude":
            cmd = [binary, "-p", prompt, "--no-input"]
        elif provider == "gemini":
            cmd = [binary, "-p", prompt]
        elif provider == "codex":
            cmd = [binary, "-p", prompt, "--quiet"]
        else:
            return ProviderCLIResult(
                status="unsupported",
                detail=f"Unsupported provider: {provider}",
                account_name=account_name,
            )

        if account_name:
            try:
                profile_dir = self.provider_diagnostics._profile_directory(provider, account_name)
            except FileNotFoundError as exc:
                return ProviderCLIResult(
                    status="session_missing",
                    detail=str(exc),
                    account_name=account_name,
                )
            env = profile_login_environment(
                provider,
                profile_dir,
                real_home=self.provider_diagnostics.source_home(),
            )
        else:
            env = self.provider_diagnostics._provider_env(provider)

        try:
            result = subprocess.run(
                cmd,
                env=env,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
            )
        except subprocess.TimeoutExpired:
            return ProviderCLIResult(
                status="timeout",
                detail=f"{provider} CLI call timed out after {timeout_seconds}s.",
                account_name=account_name,
            )
        except OSError as exc:
            return ProviderCLIResult(
                status="unavailable",
                detail=f"{provider} CLI call failed: {exc}",
                account_name=account_name,
            )

        stdout = result.stdout.strip()
        stderr = result.stderr.strip()
        combined = "\n".join(part for part in [stdout, stderr] if part).strip()
        if result.returncode == 0 and stdout:
            output = stdout
            if len(output) > max_output_length:
                output = output[:max_output_length] + "\n\n[truncated]"
            return ProviderCLIResult(
                status="ok",
                detail=combined or f"{provider} CLI call succeeded.",
                output=output,
                account_name=account_name,
                returncode=result.returncode,
                stdout=stdout or None,
                stderr=stderr or None,
            )

        status, detail = self._classify_cli_failure(provider, combined, result.returncode)
        return ProviderCLIResult(
            status=status,
            detail=detail,
            account_name=account_name,
            returncode=result.returncode,
            stdout=stdout or None,
            stderr=stderr or None,
        )

    def _classify_cli_failure(self, provider: str, message: str, returncode: int | None = None) -> tuple[str, str]:
        lowered = message.lower()
        if any(token in lowered for token in ["timed out", "timeout"]):
            return "timeout", f"{provider} CLI call timed out."
        if any(token in lowered for token in ["not logged", "login", "auth", "expired", "reauth", "credential"]):
            return "session_expired", f"{provider}: {message}" if message else f"{provider} auth expired."
        if any(token in lowered for token in ["rate limit", "too many requests", "429"]):
            return "rate_limited", f"{provider}: {message}" if message else f"{provider} rate limited."
        if returncode == 0 and not message:
            return "empty_output", f"{provider} CLI returned no output."
        if not message:
            return "empty_output" if returncode == 0 else "unavailable", f"{provider} CLI returned no output."
        return "unavailable", f"{provider}: {message}"

    def _account_auth_status_from_snapshot(self, provider: str, snapshot: dict[str, Any]) -> str:
        if bool(snapshot.get("binaryPresent")) is False:
            return "binary_missing"
        if bool(snapshot.get("sessionDetected")) is False:
            return "session_missing"
        if bool(snapshot.get("available")):
            return "ok"
        cooldown_remaining = int(snapshot.get("cooldownRemainingSeconds") or 0)
        if cooldown_remaining > 0:
            return "cooldown"

        account_name = str(snapshot.get("accountName") or "").strip()
        if account_name:
            state_key = self.provider_diagnostics._profile_account_key(provider, account_name)
            state = self.provider_diagnostics._account_state.get(state_key, {})
            failure_status = str(state.get("last_failure_status") or "").strip().lower()
            if failure_status:
                return failure_status

        auth_state = str(snapshot.get("authState") or "").strip().lower()
        if auth_state == "verified":
            return "ok"
        if auth_state == "error":
            return "session_expired"
        return "session_missing"

    def _select_account_for_provider(self, provider: str) -> str | None:
        """Select the best runnable account for a provider.

        An account is runnable only if ALL of:
        - binaryPresent (CLI installed)
        - sessionDetected (session marker exists)
        - authState verified (no last_failure_status)
        - cooldownRemainingSeconds == 0 (not on cooldown)

        Preferred account is used as a tie-break bias, not a hard blocker.
        Among runnable accounts, the chooser prefers lower request volume,
        lower recent failure pressure, then older last use.
        """
        candidates = self._candidate_accounts_for_provider(provider)
        if not candidates:
            return None

        return candidates[0]

    def _select_provider_for_recipe(
        self,
        recipe_name: str,
        health: dict[str, Any],
        excluded_providers: set[str] | None = None,
    ) -> str | None:
        """Select the best provider for a recipe based on routing preference and availability."""
        excluded = {provider.strip().lower() for provider in (excluded_providers or set()) if provider.strip()}
        preferred_order = self._recipe_routing.get(recipe_name, [])
        available = set(
            str(p).strip().lower()
            for p in (health.get("availableProviders") or [])
        )
        statuses = {
            str(s.get("providerName") or s.get("provider") or s.get("name") or "").strip().lower(): s
            for s in (health.get("providerStatuses") or [])
            if isinstance(s, dict)
        }
        now = time.time()

        for provider in preferred_order:
            if provider in excluded:
                continue
            if provider not in available:
                continue
            status = statuses.get(provider, {})
            if str(status.get("status", "")).strip().lower() not in ("ok", ""):
                continue
            with self.provider_diagnostics._snapshot_lock:
                state = self.provider_diagnostics._provider_state.get(provider, {})
                if now < float(state.get("cooldown_until", 0.0)):
                    continue
            return provider

        # Fallback to global active provider
        fallback_provider = str(health.get("activeProviderName") or "").strip().lower() or None
        if fallback_provider in excluded:
            return next((provider for provider in available if provider not in excluded), None)
        return fallback_provider

    def _post_run_health_snapshot(
        self,
        health: dict[str, Any],
        active_provider: str,
        excluded_providers: set[str],
    ) -> dict[str, Any]:
        snapshot = json.loads(json.dumps(health))
        provider_order = [
            str(provider).strip().lower()
            for provider in (snapshot.get("providerOrder") or self.provider_diagnostics._provider_order())
            if str(provider).strip()
        ]
        normalized_active = active_provider.strip().lower()
        normalized_excluded = {
            provider.strip().lower()
            for provider in excluded_providers
            if provider.strip() and provider.strip().lower() != normalized_active
        }
        provider_statuses = snapshot.get("providerStatuses") or []
        now = time.time()
        active_detail: str | None = None
        available: list[str] = []

        for diagnostic in provider_statuses:
            if not isinstance(diagnostic, dict):
                continue
            provider_name = str(
                diagnostic.get("providerName")
                or diagnostic.get("provider")
                or diagnostic.get("name")
                or ""
            ).strip().lower()
            if not provider_name:
                continue

            if provider_name == normalized_active:
                diagnostic["status"] = "ok"
                diagnostic["runnable"] = True
                diagnostic.pop("cooldownRemainingSeconds", None)
                diagnostic.pop("cooldownUntil", None)
                detail = str(diagnostic.get("detail") or f"{provider_name} selected for advisory run.").strip()
                diagnostic["detail"] = detail
                active_detail = detail
                available.append(provider_name)
                continue

            if provider_name not in normalized_excluded:
                if str(diagnostic.get("status") or "").strip().lower() == "ok":
                    diagnostic["runnable"] = True
                    available.append(provider_name)
                continue

            state = self.provider_diagnostics._provider_state.get(provider_name, {})
            failure_status = str(
                state.get("last_failure_status")
                or diagnostic.get("status")
                or "cooldown"
            ).strip().lower() or "cooldown"
            failure_detail = str(
                state.get("last_failure_detail")
                or diagnostic.get("detail")
                or f"{provider_name} temporarily unavailable."
            ).strip()
            cooldown_remaining, cooldown_until = self.provider_diagnostics._cooldown_snapshot(state, now)
            if cooldown_remaining <= 0:
                cooldown_remaining = 1
                cooldown_until = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + 1))
            diagnostic["status"] = failure_status
            diagnostic["detail"] = self.provider_diagnostics._with_cooldown_detail(
                failure_detail,
                cooldown_until,
                now,
            )
            diagnostic["runnable"] = False
            diagnostic["failureCount"] = max(
                1,
                int(state.get("failure_count", 0) or diagnostic.get("failureCount") or 0),
            )
            diagnostic["cooldownRemainingSeconds"] = cooldown_remaining
            diagnostic["cooldownUntil"] = cooldown_until

        deduped_available: list[str] = []
        for provider in [normalized_active, *provider_order, *available]:
            if provider in normalized_excluded or provider in deduped_available:
                continue
            if provider == normalized_active or provider in available:
                deduped_available.append(provider)

        snapshot["status"] = "ok"
        snapshot["activeProviderName"] = normalized_active
        snapshot["availableProviders"] = deduped_available
        snapshot["providerStatuses"] = provider_statuses
        snapshot["statusDetail"] = active_detail or f"{normalized_active} selected for advisory run."
        snapshot["lastError"] = None
        snapshot["runtimeHealthTier"] = "ok"
        snapshot["providerHealthTier"] = "ok"
        return snapshot

    def run_recipe(self, request: dict[str, Any]) -> dict[str, Any]:
        run_id = str(request.get("runId", "")).strip()
        with self._lock:
            if run_id in self._cancelled_runs:
                self._cancelled_runs.discard(run_id)
                return {
                    "runId": run_id,
                    "artifactProposals": [],
                    # continuityProposals: post-V1 feature — always empty in V1 scope
                    "continuityProposals": [],
                }

        packet = request.get("packet") or {}
        recipe_name = str(request.get("recipeName", "")).strip()
        handler = {
            "continuity_resume": self._continuity_resume,
            "thread_maintenance": self._thread_maintenance,
            "writing_seed": self._writing_seed,
            "tweet_from_thread": self._tweet_from_thread,
            "research_direction": self._research_direction,
            "weekly_reflection": self._weekly_reflection,
            "focus_reflection": self._focus_reflection,
            "social_signal": self._social_signal,
            "health_pulse": self._health_pulse,
            "decision_review": self._decision_review,
            "life_admin_review": self._life_admin_review,
        }.get(recipe_name)
        attempt_budget = self.provider_diagnostics._select_provider_attempt_budget()
        last_health: dict[str, Any] | None = None
        last_failure_detail: str | None = None
        last_failure_status: str | None = None
        excluded_providers: set[str] = set()
        preserved_health_snapshot: dict[str, Any] | None = None

        for attempt in range(attempt_budget):
            start_time = time.time()
            health = self.provider_diagnostics._quick_provider_check()
            if health is None:
                health = self.provider_diagnostics.health(force_refresh=(attempt > 0))
            last_health = health
            status = str(health.get("status") or "").strip().lower()
            if status in {"starting", "refreshing"} or bool(health.get("refreshInProgress")):
                continue
            if health["status"] != "ok":
                detail = str(health.get("statusDetail") or health["status"]).strip()
                runtime_tier = health.get("runtimeHealthTier", "ok")
                provider_tier = health.get("providerHealthTier", health["status"])
                if runtime_tier != "ok":
                    raise JsonRPCMethodError(-32001, f"Advisory runtime unavailable ({runtime_tier}): {detail}")
                raise JsonRPCMethodError(-32002, f"Advisory provider unavailable ({provider_tier}): {detail}")

            # Use recipe-specific routing instead of global activeProviderName
            provider_name = self._select_provider_for_recipe(
                recipe_name,
                health,
                excluded_providers=excluded_providers,
            )
            if not provider_name:
                break

            account_name = self._select_account_for_provider(provider_name)
            preferred_order = self._recipe_routing.get(recipe_name, [])
            if provider_name in preferred_order:
                routing_type = "recipe_primary" if preferred_order and provider_name == preferred_order[0] else "recipe_secondary"
            else:
                active_provider = str(health.get("activeProviderName") or "").strip().lower()
                routing_type = "only_available" if active_provider == provider_name else "provider_fallback"
            self._logger.info(
                "recipe_start run_id=%s recipe=%s provider=%s account=%s attempt=%d routing=%s",
                run_id, recipe_name, provider_name, account_name, attempt + 1, routing_type,
            )

            if account_name is None and self.provider_diagnostics._profile_directories(provider_name):
                last_failure_detail = f"No runnable {provider_name} accounts available."
                last_failure_status = "no_runnable"
                excluded_providers.add(provider_name)
                continue

            failure = self.provider_diagnostics._consume_fake_run_failure(provider_name)
            failure_status = str((failure or {}).get("status") or "").strip().lower()
            if failure and failure_status and failure_status != "ok":
                failure_detail = str(
                    (failure or {}).get("detail")
                    or f"{provider_name} simulated run failure ({failure_status})."
                ).strip()
                cooldown_seconds = self.provider_diagnostics._coerce_cooldown_seconds((failure or {}).get("cooldownSeconds"))
                self.provider_diagnostics._record_provider_failure_locked(
                    provider=provider_name,
                    status=failure_status,
                    detail=failure_detail,
                    now=time.time(),
                    cooldown_seconds=cooldown_seconds,
                )
                last_failure_detail = failure_detail
                last_failure_status = failure_status
                preserved_health_snapshot = self.provider_diagnostics.health(force_refresh=True)
                excluded_providers.add(provider_name)
                continue

            binding = ExecutionBinding(
                provider_name=provider_name,
                account_name=account_name,
                route_reason=routing_type,
                attempt_index=attempt + 1,
            )
            proposals = handler(packet, recipe_name, binding) if handler else []
            with self.provider_diagnostics._snapshot_lock:
                cached_health = self._post_run_health_snapshot(
                    preserved_health_snapshot or health,
                    active_provider=provider_name,
                    excluded_providers=excluded_providers,
                )
                self.provider_diagnostics._cached_health = dict(cached_health)
                self.provider_diagnostics._checked_at = time.time()
            elapsed_ms = int((time.time() - start_time) * 1000)
            self._logger.info(
                "recipe_done run_id=%s recipe=%s provider=%s account=%s latency_ms=%d fallback=%s",
                run_id, recipe_name, provider_name, account_name, elapsed_ms,
                "false" if routing_type == "recipe_primary" else "true",
            )
            return {
                "runId": run_id,
                "artifactProposals": proposals,
                # continuityProposals: post-V1 feature — always empty in V1 scope
                "continuityProposals": [],
            }

        failure_status = last_failure_status or str(last_health.get("status") if last_health else "no_provider")
        if last_failure_detail:
            failure_detail = last_failure_detail
        elif last_health:
            failure_detail = str(last_health.get("statusDetail") or last_health.get("lastError") or failure_status)
        else:
            failure_detail = "No provider available"
        self._logger.warning(
            "recipe_exhausted run_id=%s recipe=%s last_status=%s last_detail=%s",
            run_id, recipe_name, failure_status, failure_detail,
        )
        raise JsonRPCMethodError(-32002, f"Advisory provider exhausted ({failure_status}): {failure_detail}")

    def _continuity_resume(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        thread = self._primary_thread(packet)
        if thread is None:
            return []

        note = next(iter(self._notes_enrichment(packet)), None)
        calendar = self._enrichment_item(packet, "calendar")
        reminder = self._enrichment_item(packet, "reminders")
        timing_window = self._timing_window_hint(
            calendar_item=calendar,
            reminder_item=reminder,
            trigger_kind=str(packet.get("triggerKind", "")).strip(),
            prefer_transition=str(packet.get("triggerKind", "")).strip() != "morning_resume",
        )
        items = [
            item
            for item in packet.get("candidateContinuityItems", [])
            if item.get("threadId") in (None, thread.get("id"))
        ]
        open_loop = items[0]["title"] if items else "нить пока больше чувствуется, чем сформулирована"
        decision_text = next((item.get("body") for item in items if item.get("kind") == "decision" and item.get("body")), None)
        continuations = self._suggested_continuations(thread, items, packet.get("salientSessions", []))

        # Try provider CLI for richer generation
        cli_generation_failed: bool | None = None
        generated_by = "fallback:heuristic"
        provider_output: str | None = None
        actual_account_name = binding.account_name
        if self._should_use_provider_cli(binding.provider_name):
            context_parts = [
                f"Thread: {thread['title']}",
                f"Summary: {thread.get('summary', 'N/A')}",
                f"Open loop: {open_loop}",
            ]
            if decision_text:
                context_parts.append(f"Decision: {self._clean_snippet(decision_text, 160)}")
            if note:
                context_parts.append(f"Note: {note.get('title', '')} — {note.get('snippet', '')}")
            prompt = (
                "You are a personal continuity advisor. Based on the context below, "
                "write a warm, concise resume card (3-5 sentences in Russian) helping the user "
                "return to their main thread. Include 3 concrete re-entry points.\n\n"
                + "\n".join(context_parts)
            )
            cli_result = self._run_provider_cli_with_failover(
                binding.provider_name,
                prompt,
                account_name=binding.account_name,
                recipe_name=recipe_name,
            )
            provider_output = cli_result.output
            actual_account_name = cli_result.account_name or actual_account_name
            if cli_result.ok:
                generated_by = f"cli:{binding.provider_name}"
            else:
                cli_generation_failed = True

        if provider_output:
            body = provider_output
        else:
            lines = [f"Я заметил, что главная нить сейчас: {thread['title']}."]
            if thread.get("summary"):
                lines.append(f"Где остановился: {thread['summary']}")
            lines.append(f"Похоже, незакрытый узел здесь: {open_loop}.")
            if decision_text:
                lines.append(f"Что уже решено: {self._clean_snippet(decision_text, 160)}")
            if note:
                lines.append(
                    f"Из заметок здесь уже держится опора: «{note.get('title', 'заметка')}» — {note.get('snippet', '')}"
                )
            if reminder:
                lines.append(f"Есть и внешний anchor: {self._enrichment_anchor(reminder)}.")
            elif calendar:
                lines.append(f"Есть и внешний anchor: {self._enrichment_anchor(calendar)}.")
            if timing_window:
                lines.append(f"По timing fit мягче всего возвращаться {timing_window}.")
            lines.append("Если хочешь продолжить, вот 3 хороших входа:")
            for index, option in enumerate(continuations[:3], start=1):
                lines.append(f"{index}. {option}")
            body = "\n".join(lines)

        return [
            self._artifact(
                packet=packet,
                domain="continuity",
                kind="resume_card",
                title=f"Вернуться в {thread['title']}",
                body=body,
                recipe_name=recipe_name,
                thread_id=thread.get("id"),
                confidence=max(0.55, min(0.95, float(thread.get("confidence", 0.75)))),
                why_now=self._why_now(packet.get("triggerKind", "")),
                metadata_json=self._guidance_metadata(
                    summary=str(thread.get("summary", "")).strip() or None,
                    evidence_pack=packet.get("evidenceRefs", [])[:3],
                    action_steps=continuations,
                    continuity_anchor=continuations[0] if continuations else None,
                    open_loop=open_loop,
                    decision_text=decision_text,
                    pattern_name="Resume Me",
                    note_anchor_title=str(note.get("title", "")).strip() if note else None,
                    note_anchor_snippet=str(note.get("snippet", "")).strip() if note else None,
                    source_anchors=self._source_anchors(note, calendar, reminder),
                    enrichment_sources=self._enrichment_sources(note, calendar, reminder),
                    timing_window=timing_window,
                    generated_by=generated_by,
                    provider=binding.provider_name,
                    cli_generation_failed=cli_generation_failed,
                    account=actual_account_name,
                    route_reason=binding.route_reason,
                ),
            )
        ]

    def _thread_maintenance(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        threads = packet.get("candidateThreadRefs", [])
        if len(threads) < 2:
            return []

        body_lines = [
            "Похоже, thread layer просит тихого обслуживания, не срочного cleanup.",
            "Это не про порядок ради порядка, а про то, чтобы завтра утром вход обратно был дешевле.",
        ]
        parent_relations = []
        by_id = {thread.get("id"): thread for thread in threads}
        for thread in threads:
            parent = by_id.get(thread.get("parentThreadId"))
            if parent:
                parent_relations.append(
                    f"Похоже, «{thread['title']}» лучше воспринимать как подпоток нити «{parent['title']}»."
                )
        if parent_relations:
            body_lines.append("Возможные merge / nesting moves:")
            for index, line in enumerate(parent_relations[:2], start=1):
                body_lines.append(f"{index}. {line}")

        broad_thread = next(
            (
                thread
                for thread in sorted(threads, key=lambda item: int(item.get("totalActiveMinutes", 0)), reverse=True)
                if not thread.get("parentThreadId") and int(thread.get("totalActiveMinutes", 0)) >= 150
            ),
            None,
        )
        if broad_thread is not None:
            body_lines.append(
                f"Нить «{broad_thread['title']}» уже выглядит слишком широкой; возможно, внутри неё созрел отдельный sub-thread."
            )

        body_lines.extend(
            [
                "Если захочешь пройтись мягко:",
                "1. Склеить явные overlap-нитки, но не терять evidence.",
                "2. Узкие подпотоки отметить как children, а не держать рядом как дубли.",
                "3. Старые нити без движения перевести в parked или resolved, чтобы они не шумели в Resume Me.",
            ]
        )

        return [
            self._artifact(
                packet=packet,
                domain="continuity",
                kind="reflection_card",
                title="Нити просят maintenance",
                body="\n".join(body_lines),
                recipe_name=recipe_name,
                thread_id=threads[0].get("id"),
                confidence=min(0.86, 0.48 + max(self._signal(packet, "thread_density"), self._signal(packet, "continuity_pressure")) * 0.28),
                why_now="Thread maintenance имеет смысл только когда уже видны устойчивые нити, а не в cold start bootstrap.",
                metadata_json=self._guidance_metadata(
                    summary="Thread layer просит maintenance.",
                    evidence_pack=packet.get("evidenceRefs", [])[:3],
                    action_steps=[
                        "Склеить overlap-нитки без потери evidence.",
                        "Узкие подпотоки отметить как children.",
                        "Старые тихие нити перевести в parked или resolved.",
                    ],
                    pattern_name="Thread Maintenance",
                    generated_by="fallback:heuristic",
                    provider=binding.provider_name,
                    account=binding.account_name,
                    route_reason=binding.route_reason,
                ),
            )
        ]

    def _writing_seed(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        thread = self._primary_thread(packet)
        if (
            thread is None
            or self._signal(packet, "expression_pull") < 0.25
            or self._matched_avoid_topic(packet, thread) is not None
        ):
            return []

        primary_angle = self._preferred_angle(packet, fallback="observation")
        alternative_angles = self._alternative_angles(packet, primary_angle)
        persona = self._persona(packet)
        voice_examples = (packet.get("constraints", {}).get("twitterVoiceExamples") or [])[:2]
        avoid_topics = self._normalized_avoid_topics(packet)
        evidence_pack = packet.get("evidenceRefs", [])[:3]
        kind = self._writing_artifact_kind(packet, thread, primary_angle)
        note = self._enrichment_item(packet, "notes")
        web_research = self._enrichment_item(packet, "web_research")
        calendar = self._enrichment_item(packet, "calendar")
        reminder = self._enrichment_item(packet, "reminders")
        timing_window = self._timing_window_hint(
            calendar_item=calendar,
            reminder_item=reminder,
            trigger_kind=str(packet.get("triggerKind", "")).strip(),
            prefer_transition=str(packet.get("triggerKind", "")).strip() != "user_invoked_write",
        )
        metadata = {
            "primaryAngle": primary_angle,
            "alternativeAngles": alternative_angles,
            "evidencePack": evidence_pack,
            "voiceExamples": voice_examples,
            "avoidTopics": avoid_topics,
            "personaDescription": persona,
            "suggestedOpenings": [
                self._tweet_opening(primary_angle, thread, packet),
                self._tweet_opening(alternative_angles[0] if alternative_angles else "question", thread, packet),
            ],
            "continuityAnchor": None,
            "sourceAnchors": self._source_anchors(note, web_research, calendar, reminder),
            "enrichmentSources": self._enrichment_sources(note, web_research, calendar, reminder),
            "timingWindow": timing_window,
            "generatedBy": "fallback:heuristic",
            "provider": binding.provider_name,
            "account": binding.account_name,
            "routeReason": binding.route_reason,
        }

        lines = [
            self._writing_opening(kind, thread),
            f"Persona: {persona}",
            f"Angle: {primary_angle}.",
            f"Evidence pack: {', '.join(evidence_pack)}.",
            f"Alternative angles: {' | '.join(alternative_angles)}.",
        ]
        if voice_examples:
            lines.append(f"Voice examples: {' | '.join(voice_examples)}.")
        if avoid_topics:
            lines.append(f"Avoid topics: {', '.join(avoid_topics)}.")
        if note:
            lines.append(f"Note anchor: {note.get('title', 'заметка')} — {note.get('snippet', '')}")
        if web_research:
            lines.append(f"Context anchor: {self._enrichment_anchor(web_research)}")
        if timing_window:
            lines.append(f"Timing: {timing_window}")
        lines.append("Почему это может сработать: нить уже заземлена в lived context, а не в generic AI abstraction.")
        lines.extend(self._writing_structure(kind, packet, thread, primary_angle, alternative_angles))
        return [
            self._artifact(
                packet=packet,
                domain="writing_expression",
                kind=kind,
                title=self._writing_title(kind, thread),
                body="\n".join(lines),
                recipe_name=recipe_name,
                thread_id=thread.get("id"),
                confidence=self._writing_confidence(kind, packet, thread),
                why_now=self._writing_why_now(kind, packet),
                metadata_json=json.dumps(metadata, ensure_ascii=False),
            )
        ]

    def _tweet_from_thread(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        thread = self._thread_packet_thread(packet)
        if (
            thread is None
            or self._signal(packet, "expression_pull") < 0.25
            or self._matched_avoid_topic(packet, thread) is not None
        ):
            return []

        primary_angle = self._preferred_angle(packet, fallback="observation")
        alternative_angles = self._alternative_angles(packet, primary_angle)
        persona = self._persona(packet)
        voice_examples = (packet.get("constraints", {}).get("twitterVoiceExamples") or [])[:2]
        avoid_topics = self._normalized_avoid_topics(packet)
        evidence_pack = packet.get("evidenceRefs", [])[:4]
        continuity_state = packet.get("continuityState") or {}
        kind = self._thread_writing_artifact_kind(packet, thread, primary_angle)
        note = self._enrichment_item(packet, "notes")
        web_research = self._enrichment_item(packet, "web_research")
        calendar = self._enrichment_item(packet, "calendar")
        reminder = self._enrichment_item(packet, "reminders")
        timing_window = self._timing_window_hint(
            calendar_item=calendar,
            reminder_item=reminder,
            trigger_kind=str(packet.get("triggerKind", "")).strip(),
            prefer_transition=True,
        )
        metadata = {
            "primaryAngle": primary_angle,
            "alternativeAngles": alternative_angles,
            "evidencePack": evidence_pack,
            "voiceExamples": voice_examples,
            "avoidTopics": avoid_topics,
            "personaDescription": persona,
            "suggestedOpenings": [
                self._thread_tweet_opening(primary_angle, thread.get("title", "эта нить")),
                self._thread_tweet_opening(
                    alternative_angles[0] if alternative_angles else "question",
                    thread.get("title", "эта нить"),
                ),
            ],
            "continuityAnchor": continuity_state.get("suggestedEntryPoint"),
            "sourceAnchors": self._source_anchors(note, web_research, calendar, reminder),
            "enrichmentSources": self._enrichment_sources(note, web_research, calendar, reminder),
            "timingWindow": timing_window,
        }

        # Try provider CLI for richer generation
        tweet_cli_generation_failed: bool | None = None
        generated_by = "fallback:heuristic"
        provider_output: str | None = None
        actual_account_name = binding.account_name
        if self._should_use_provider_cli(binding.provider_name):
            prompt = (
                "You are a tweet ghostwriter. Based on the context below, suggest 3 tweet angles "
                "grounded in the thread evidence. Each angle: one sentence + a draft tweet (280 chars max). "
                "Write in the user's voice (examples below). Output in Russian.\n\n"
                f"Thread: {thread.get('title', '')}\n"
                f"Angle: {primary_angle}\n"
                f"Evidence: {', '.join(evidence_pack)}\n"
            )
            if voice_examples:
                prompt += f"Voice examples: {' | '.join(voice_examples)}\n"
            cli_result = self._run_provider_cli_with_failover(
                binding.provider_name,
                prompt,
                account_name=binding.account_name,
                recipe_name=recipe_name,
            )
            provider_output = cli_result.output
            actual_account_name = cli_result.account_name or actual_account_name
            if cli_result.ok:
                generated_by = f"cli:{binding.provider_name}"
            else:
                tweet_cli_generation_failed = True

        if provider_output:
            body = provider_output
        else:
            lines = [
                self._thread_writing_opening(kind, thread),
                f"Persona: {persona}",
                f"Angle: {primary_angle}.",
                f"Evidence pack: {', '.join(evidence_pack)}.",
                f"Alternative angles: {' | '.join(alternative_angles)}.",
            ]
            if voice_examples:
                lines.append(f"Voice examples: {' | '.join(voice_examples)}.")
            if avoid_topics:
                lines.append(f"Avoid topics: {', '.join(avoid_topics)}.")
            if continuity_state.get("suggestedEntryPoint"):
                lines.append(f"Continuity anchor: {continuity_state['suggestedEntryPoint']}")
            if note:
                lines.append(f"Note anchor: {note.get('title', 'заметка')} — {note.get('snippet', '')}")
            if web_research:
                lines.append(f"Context anchor: {self._enrichment_anchor(web_research)}")
            if timing_window:
                lines.append(f"Timing: {timing_window}")
            lines.extend(self._thread_writing_structure(kind, packet, primary_angle, alternative_angles))
            body = "\n".join(lines)

        metadata["generatedBy"] = generated_by
        metadata["provider"] = binding.provider_name
        if tweet_cli_generation_failed is not None:
            metadata["cliGenerationFailed"] = tweet_cli_generation_failed
        metadata["account"] = actual_account_name
        metadata["routeReason"] = binding.route_reason
        return [
            self._artifact(
                packet=packet,
                domain="writing_expression",
                kind=kind,
                title=self._writing_title(kind, thread),
                body=body,
                recipe_name=recipe_name,
                thread_id=thread.get("id"),
                confidence=self._thread_writing_confidence(kind, packet, thread),
                why_now=self._thread_writing_why_now(kind),
                metadata_json=json.dumps(metadata, ensure_ascii=False),
            )
        ]

    def _research_direction(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        research_pull = self._signal(packet, "research_pull")
        if research_pull < self._adjusted_minimum_signal(packet, 0.3, 0.12):
            return []

        note = next(iter(self._notes_enrichment(packet)), None)
        web_research = self._enrichment_item(packet, "web_research")
        calendar = self._enrichment_item(packet, "calendar")
        timing_window = self._timing_window_hint(
            calendar_item=calendar,
            reminder_item=None,
            trigger_kind=str(packet.get("triggerKind", "")).strip(),
            prefer_transition=False,
        )
        topic = (
            str((web_research or {}).get("title", "")).strip()
            or next(iter(packet.get("activeEntities", [])[1:2]), "")
            or next(iter(packet.get("activeEntities", [])[:1]), "текущая нить")
        )
        thread = self._primary_thread(packet)
        focus_question = f"Что именно в {topic} остаётся недоказанным или плохо объяснённым?"
        action_steps = [
            "Сформулировать один рабочий вопрос.",
            "Собрать 2 контрастных примера из текущего контекста.",
            f"Зафиксировать, что изменится в нити {thread['title'] if thread else topic}, если ответ подтвердится.",
        ]
        kind = "exploration_seed" if note is None and web_research is None and research_pull >= 0.7 else "research_direction"
        lines = [
            f"Здесь уже назрел exploration seed вокруг {topic}, но без требования сразу всё доказать."
            if kind == "exploration_seed"
            else f"Похоже, здесь есть исследовательская тяга вокруг {topic}.",
            "Хороший следующий ход: открыть узкое exploration window и посмотреть, какая гипотеза вообще выдерживает реальный контекст."
            if kind == "exploration_seed"
            else "Хорошее исследовательское направление сейчас: не расширять поле, а проверить один узкий вопрос, который снимет неопределённость.",
            f"Фокус вопроса: {focus_question}",
        ]
        if note:
            lines.append(
                f"Из заметок уже резонирует: «{note.get('title', 'заметка')}» — {note.get('snippet', '')}"
            )
        if web_research:
            lines.append(
                f"Из browser context уже тянется: «{web_research.get('title', 'web context')}» — {web_research.get('snippet', '')}"
            )
        if timing_window and kind == "research_direction":
            lines.append(f"Если брать это без спешки, лучшее окно здесь {timing_window}.")
        lines.append("Если захочешь копнуть:")
        for index, step in enumerate(action_steps, start=1):
            lines.append(f"{index}. {step}")
        return [
            self._artifact(
                packet=packet,
                domain="research",
                kind=kind,
                title=f"Exploration seed: {topic}" if kind == "exploration_seed" else f"Исследовательское направление: {topic}",
                body="\n".join(lines),
                recipe_name=recipe_name,
                thread_id=thread.get("id") if thread else None,
                confidence=min(0.86, 0.5 + research_pull * 0.34),
                why_now="Research signal уже повторился достаточно, чтобы дать направление, а не просто curiosity noise.",
                metadata_json=self._guidance_metadata(
                    summary=f"Exploration window around {topic}." if kind == "exploration_seed" else f"Research direction around {topic}.",
                    evidence_pack=packet.get("evidenceRefs", [])[:3],
                    action_steps=action_steps,
                    focus_question=focus_question,
                    note_anchor_title=str(note.get("title", "")).strip() if note else None,
                    note_anchor_snippet=str(note.get("snippet", "")).strip() if note else None,
                    source_anchors=self._source_anchors(note, web_research, calendar),
                    enrichment_sources=self._enrichment_sources(note, web_research, calendar),
                    timing_window=timing_window,
                    generated_by="fallback:heuristic",
                    provider=binding.provider_name,
                    account=binding.account_name,
                    route_reason=binding.route_reason,
                ),
            )
        ]

    def _weekly_reflection(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        thread_rollup = packet.get("threadRollup", [])
        if not thread_rollup:
            return []

        dominant_thread = thread_rollup[0]
        top_pattern = next(iter(packet.get("patterns", [])), None)
        continuity_items = packet.get("continuityItems", [])
        note = self._enrichment_item(packet, "notes")
        web_research = self._enrichment_item(packet, "web_research")
        calendar = self._enrichment_item(packet, "calendar")
        reminder = self._enrichment_item(packet, "reminders")
        timing_window = self._timing_window_hint(
            calendar_item=calendar,
            reminder_item=reminder,
            trigger_kind=str(packet.get("triggerKind", "")).strip(),
            prefer_transition=True,
        )
        action_steps = [
            "Назвать 1-2 нити, которые реально тянули неделю.",
            "Отметить, что из этого уже стало яснее.",
            "Оставить один return point на следующую неделю.",
        ]

        # Try provider CLI for richer weekly synthesis
        weekly_cli_generation_failed: bool | None = None
        generated_by = "fallback:heuristic"
        provider_output: str | None = None
        actual_account_name = binding.account_name
        if self._should_use_provider_cli(binding.provider_name):
            thread_titles = [t.get("title", "") for t in thread_rollup[:5]]
            prompt = (
                "You are a weekly reflection advisor. Synthesize this week's thread movement into "
                "a warm weekly review (5-8 sentences in Russian). Include: which threads moved, "
                "what stalled, emerging lines, and one return point for next week.\n\n"
                f"Threads: {', '.join(thread_titles)}\n"
                f"Dominant thread: {dominant_thread.get('title', '')}\n"
            )
            if top_pattern:
                prompt += f"Top pattern: {top_pattern.get('summary', top_pattern.get('title', ''))}\n"
            if continuity_items:
                open_loops = [item.get("title", "") for item in continuity_items[:3]]
                prompt += f"Open loops: {', '.join(open_loops)}\n"
            cli_result = self._run_provider_cli_with_failover(
                binding.provider_name,
                prompt,
                account_name=binding.account_name,
                recipe_name=recipe_name,
            )
            provider_output = cli_result.output
            actual_account_name = cli_result.account_name or actual_account_name
            if cli_result.ok:
                generated_by = f"cli:{binding.provider_name}"
            else:
                weekly_cli_generation_failed = True

        if provider_output:
            body = provider_output
        else:
            lines = [
                "Неделя уже выглядит достаточно собранной, чтобы оставить один мягкий weekly anchor.",
                "Это не попытка закрыть всё разом, а способ вернуть себе быстрый вход в основные нити в начале следующей недели.",
                f"Главная несущая нить недели: {dominant_thread.get('title', 'главная нить')}.",
            ]
            if top_pattern:
                lines.append(f"Самый заметный паттерн: {top_pattern.get('summary', top_pattern.get('title', 'паттерн недели'))}")
            if note:
                lines.append(f"Из заметок неделя уже держится через: «{note.get('title', 'заметка')}» — {note.get('snippet', '')}")
            if web_research:
                lines.append(f"Во внешнем контексте тоже тянется: {self._enrichment_anchor(web_research)}")
            if reminder:
                lines.append(f"На следующую неделю уже виден мягкий anchor: {self._enrichment_anchor(reminder)}.")
            elif calendar:
                lines.append(f"На следующую неделю уже виден мягкий anchor: {self._enrichment_anchor(calendar)}.")
            if timing_window:
                lines.append(f"Если оставить return point мягко, лучше делать это {timing_window}.")
            if continuity_items:
                lines.append("Открытые loops, которые стоит не потерять:")
                for index, item in enumerate(continuity_items[:3], start=1):
                    lines.append(f"{index}. {item.get('title', 'continuity item')}")
            lines.extend(
                [
                    "Если захочешь зафиксировать неделю коротко:",
                    f"1. {action_steps[0]}",
                    f"2. {action_steps[1]}",
                    f"3. {action_steps[2]}",
                ]
            )
            body = "\n".join(lines)

        return [
            self._artifact(
                packet=packet,
                domain="continuity",
                kind="weekly_review",
                title="Weekly review: собрать несущие нити недели",
                body=body,
                recipe_name=recipe_name,
                thread_id=dominant_thread.get("id"),
                confidence=min(0.88, 0.52 + self._signal(packet, "continuity_pressure") * 0.18 + self._signal(packet, "thread_density") * 0.14),
                why_now="Weekly review полезен, когда уже видны повторяющиеся нити и continuity pressure, а не просто сумма дней.",
                metadata_json=self._guidance_metadata(
                    summary=str(dominant_thread.get("summary", "")).strip() or (str(top_pattern.get("summary", "")).strip() if top_pattern else None),
                    evidence_pack=packet.get("evidenceRefs", [])[:4],
                    action_steps=action_steps,
                    continuity_anchor=action_steps[-1],
                    open_loop=str(continuity_items[0].get("title", "")).strip() if continuity_items else None,
                    note_anchor_title=str(note.get("title", "")).strip() if note else None,
                    note_anchor_snippet=str(note.get("snippet", "")).strip() if note else None,
                    pattern_name=str(top_pattern.get("title", "")).strip() if top_pattern else None,
                    source_anchors=self._source_anchors(note, web_research, calendar, reminder),
                    enrichment_sources=self._enrichment_sources(note, web_research, calendar, reminder),
                    timing_window=timing_window,
                    generated_by=generated_by,
                    provider=binding.provider_name,
                    cli_generation_failed=weekly_cli_generation_failed,
                    account=actual_account_name,
                    route_reason=binding.route_reason,
                ),
            )
        ]

    def _focus_reflection(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        focus_turbulence = self._signal(packet, "focus_turbulence")
        if focus_turbulence < self._adjusted_minimum_signal(packet, 0.32, 0.2):
            return []
        fragmentation = self._signal(packet, "fragmentation")
        kind = "focus_intervention" if fragmentation >= 0.55 or str(packet.get("triggerKind", "")).strip() == "focus_break_natural" else "pattern_notice"
        calendar = self._enrichment_item(packet, "calendar")
        reminder = self._enrichment_item(packet, "reminders")
        rhythm = self._enrichment_item(packet, "wearable")
        timing_window = self._timing_window_hint(
            calendar_item=calendar,
            reminder_item=reminder,
            trigger_kind=str(packet.get("triggerKind", "")).strip(),
            prefer_transition=True,
        )
        action_steps = [
            "Вернуться в уже тёплую нить, а не открывать новую.",
            "Сузить следующий шаг до одного проверяемого результата.",
            "Отложить побочные идеи в note seed вместо немедленного переключения.",
        ]

        lines = [
            "Я заметил, что день выглядит фрагментированным сильнее обычного.",
            "Похоже, re-entry cost сейчас растёт не из-за сложности одной нити, а из-за частых входов и выходов между ними.",
            "Похоже, сейчас полезнее мягкая focus intervention, а не ещё один анализ паттерна."
            if kind == "focus_intervention"
            else "Самый мягкий фокус-сдвиг здесь: выбрать одну нить как anchor и не добавлять новых контекстов до первого завершённого мини-шага.",
        ]
        if rhythm:
            lines.append(f"И по rhythm context тоже видно: {self._enrichment_anchor(rhythm)}.")
        if reminder:
            lines.append(f"Из внешнего контекста сейчас заметен transition anchor: {self._enrichment_anchor(reminder)}.")
        elif calendar:
            lines.append(f"Из внешнего контекста сейчас заметен transition anchor: {self._enrichment_anchor(calendar)}.")
        if timing_window:
            lines.append(f"Если делать мягкий reset, лучше всего делать его {timing_window}.")
        lines.extend(
            [
                "Хорошие входы:",
                f"1. {action_steps[0]}",
                f"2. {action_steps[1]}",
                f"3. {action_steps[2]}",
            ]
        )
        return [
            self._artifact(
                packet=packet,
                domain="focus",
                kind=kind,
                title="Сделать один мягкий focus reset" if kind == "focus_intervention" else "Паттерн дня: растущий re-entry cost",
                body="\n".join(lines),
                recipe_name=recipe_name,
                thread_id=self._primary_thread(packet).get("id") if self._primary_thread(packet) else None,
                confidence=min(0.84, 0.5 + focus_turbulence * 0.28),
                why_now="Focus domain поднялся из контекста дня, а не из абстрактного coaching.",
                metadata_json=self._guidance_metadata(
                    summary="Re-entry cost is rising.",
                    evidence_pack=packet.get("evidenceRefs", [])[:3],
                    action_steps=action_steps,
                    pattern_name="Focus Intervention" if kind == "focus_intervention" else "Pattern Notice",
                    source_anchors=self._source_anchors(rhythm, calendar, reminder),
                    enrichment_sources=self._enrichment_sources(rhythm, calendar, reminder),
                    timing_window=timing_window,
                    generated_by="fallback:heuristic",
                    provider=binding.provider_name,
                    account=binding.account_name,
                    route_reason=binding.route_reason,
                ),
            )
        ]

    def _social_signal(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        if self._signal(packet, "social_pull") < self._adjusted_minimum_signal(packet, 0.34, 0.2):
            return []
        web_research = self._enrichment_item(packet, "web_research")
        calendar = self._enrichment_item(packet, "calendar")
        reminder = self._enrichment_item(packet, "reminders")
        topic = str((web_research or {}).get("title", "")).strip() or next(iter(packet.get("activeEntities", [])[:1]), "социальный сигнал")
        primary_angle = self._preferred_angle(packet, fallback="provocation" if packet.get("constraints", {}).get("allowProvocation") else "observation")
        alternative_angles = self._alternative_angles(packet, primary_angle)
        timing_window = self._timing_window_hint(
            calendar_item=calendar,
            reminder_item=reminder,
            trigger_kind=str(packet.get("triggerKind", "")).strip(),
            prefer_transition=True,
        )
        lines = [
            "Из сегодняшнего контекста может получиться social signal, но без ощущения forced posting.",
            f"Угол: {topic}.",
            "Почему это может сработать: здесь уже есть lived evidence и не нужно выдумывать позицию.",
            f"Primary angle: {primary_angle}.",
            f"Alternative angles: {' | '.join(alternative_angles)}.",
            f"Evidence pack: {', '.join(packet.get('evidenceRefs', [])[:3])}.",
        ]
        if web_research:
            lines.append(
                f"Материал уже grounded в browser context: «{web_research.get('title', 'web context')}» — {web_research.get('snippet', '')}"
            )
        if reminder:
            lines.append(f"Есть и мягкий внешний anchor: {self._enrichment_anchor(reminder)}.")
        elif calendar:
            lines.append(f"Есть и мягкий внешний anchor: {self._enrichment_anchor(calendar)}.")
        if timing_window:
            lines.append(f"По timing fit лучше всего смотреть на это {timing_window}.")
        lines.extend(
            [
                "Черновой вход:",
                "\"Поймал интересную нить: ...\"",
                "Дальше можно дать 1 observation, 1 implication и 1 открытый вопрос.",
            ]
        )
        return [
            self._artifact(
                packet=packet,
                domain="social",
                kind="social_nudge",
                title="Social signal из текущей нити",
                body="\n".join(lines),
                recipe_name=recipe_name,
                thread_id=self._primary_thread(packet).get("id") if self._primary_thread(packet) else None,
                confidence=min(0.8, 0.45 + self._signal(packet, "social_pull") * 0.3),
                why_now="Social candidate заземлён в сегодняшнем материале, а не в пустой контентной повинности.",
                metadata_json=self._guidance_metadata(
                    summary="Grounded social signal from today.",
                    primary_angle=primary_angle,
                    alternative_angles=alternative_angles,
                    evidence_pack=packet.get("evidenceRefs", [])[:3],
                    action_steps=[
                        "Один observation.",
                        "Один implication.",
                        "Один открытый вопрос.",
                    ],
                    source_anchors=self._source_anchors(web_research, calendar, reminder),
                    enrichment_sources=self._enrichment_sources(web_research, calendar, reminder),
                    timing_window=timing_window,
                    generated_by="fallback:heuristic",
                    provider=binding.provider_name,
                    account=binding.account_name,
                    route_reason=binding.route_reason,
                ),
            )
        ]

    def _health_pulse(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        if self._signal(packet, "health_pressure") < self._adjusted_minimum_signal(packet, 0.36, 0.24):
            return []
        calendar = self._enrichment_item(packet, "calendar")
        reminder = self._enrichment_item(packet, "reminders")
        rhythm = self._enrichment_item(packet, "wearable")
        timing_window = self._timing_window_hint(
            calendar_item=calendar,
            reminder_item=reminder,
            trigger_kind=str(packet.get("triggerKind", "")).strip(),
            prefer_transition=True,
        )
        lines = [
            "По косвенным сигналам день выглядит более рваным и тяжёлым по ритму.",
            "Это не диагноз и не score, а мягкое замечание: возможно, полезнее уменьшить стоимость следующего входа, чем форсировать глубину.",
        ]
        if rhythm:
            lines.append(f"И по rhythm layer тоже видно: {self._enrichment_anchor(rhythm)}.")
        if reminder:
            lines.append(f"Снаружи тоже виден нагрузочный anchor: {self._enrichment_anchor(reminder)}.")
        elif calendar:
            lines.append(f"Снаружи тоже виден нагрузочный anchor: {self._enrichment_anchor(calendar)}.")
        if timing_window:
            lines.append(f"Если делать мягкий сдвиг, лучше искать его {timing_window}.")
        lines.extend(
            [
                "Если хочешь бережный сдвиг:",
                "1. Выбрать самую тёплую нить.",
                "2. Сделать один короткий проход вместо большого блока.",
                "3. Оставить себе явный return point на потом.",
            ]
        )
        return [
            self._artifact(
                packet=packet,
                domain="health",
                kind="health_reflection",
                title="Ритм дня выглядит перегруженным",
                body="\n".join(lines),
                recipe_name=recipe_name,
                thread_id=self._primary_thread(packet).get("id") if self._primary_thread(packet) else None,
                confidence=min(0.74, 0.42 + self._signal(packet, "health_pressure") * 0.24),
                why_now="Health domain включается только при заметном косвенном signal, без морализаторства.",
                metadata_json=self._guidance_metadata(
                    summary="Day rhythm looks overloaded.",
                    evidence_pack=packet.get("evidenceRefs", [])[:3],
                    action_steps=[
                        "Выбрать самую тёплую нить.",
                        "Сделать один короткий проход вместо большого блока.",
                        "Оставить себе явный return point на потом.",
                    ],
                    pattern_name="Health Reflection",
                    source_anchors=self._source_anchors(rhythm, calendar, reminder),
                    enrichment_sources=self._enrichment_sources(rhythm, calendar, reminder),
                    timing_window=timing_window,
                    generated_by="fallback:heuristic",
                    provider=binding.provider_name,
                    account=binding.account_name,
                    route_reason=binding.route_reason,
                ),
            )
        ]

    def _decision_review(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        decision_density = self._signal(packet, "decision_density")
        if decision_density < self._adjusted_minimum_signal(packet, 0.24, 0.16):
            return []
        thread = self._primary_thread(packet)
        reminder = self._enrichment_item(packet, "reminders")
        calendar = self._enrichment_item(packet, "calendar")
        timing_window = self._timing_window_hint(
            calendar_item=calendar,
            reminder_item=reminder,
            trigger_kind=str(packet.get("triggerKind", "")).strip(),
            prefer_transition=True,
        )
        explicit_decision = next((item for item in packet.get("candidateContinuityItems", []) if item.get("kind") == "decision"), None)
        kind = "missed_signal" if explicit_decision is None else "decision_reminder"
        decision_text = (
            (explicit_decision or {}).get("body")
            or (explicit_decision or {}).get("title")
            or (reminder or {}).get("title")
            or (calendar or {}).get("title")
            or (thread or {}).get("summary")
            or "implicit branch choice"
        )
        action_steps = (
            [
                "Назвать развилку одним предложением.",
                "Записать, какой implicit выбор уже случился.",
                "Решить, нужно ли его закрепить явно.",
            ]
            if kind == "missed_signal"
            else [
                "Что именно было выбрано.",
                "Что было отвергнуто и почему.",
                "Какой следующий эффект это создаёт для текущей нити.",
            ]
        )
        lines = [
            "Похоже, в этой нити был implicit choice, который лучше не оставлять неявным."
            if kind == "missed_signal"
            else "Похоже, в этой нити были решения, которые лучше зафиксировать, пока контекст ещё тёплый.",
            f"Что стоит зафиксировать: {self._clean_snippet(decision_text, 170)}.",
        ]
        if reminder:
            lines.append(f"Есть и внешний operational anchor: {self._enrichment_anchor(reminder)}.")
        elif calendar:
            lines.append(f"Есть и внешний operational anchor: {self._enrichment_anchor(calendar)}.")
        if timing_window:
            lines.append(f"Хорошее окно для такой фиксации {timing_window}.")
        lines.extend(
            [
                "Хороший минимальный формат:",
                f"1. {action_steps[0]}",
                f"2. {action_steps[1]}",
                f"3. {action_steps[2]}",
            ]
        )
        return [
            self._artifact(
                packet=packet,
                domain="decisions",
                kind=kind,
                title="Назвать пропущенный decision signal" if kind == "missed_signal" else "Зафиксировать решение, пока оно свежее",
                body="\n".join(lines),
                recipe_name=recipe_name,
                thread_id=thread.get("id") if thread else None,
                confidence=min(0.83, 0.48 + decision_density * 0.3),
                why_now="Decision domain важен, пока развилка ещё связана с реальным evidence сегодняшнего дня.",
                metadata_json=self._guidance_metadata(
                    summary="Implicit decision signal detected." if kind == "missed_signal" else "Decision worth fixing explicitly.",
                    evidence_pack=packet.get("evidenceRefs", [])[:3],
                    action_steps=action_steps,
                    decision_text=str(decision_text).strip() or None,
                    pattern_name="Missed Signal" if kind == "missed_signal" else "Decision Reminder",
                    source_anchors=self._source_anchors(reminder, calendar),
                    enrichment_sources=self._enrichment_sources(reminder, calendar),
                    timing_window=timing_window,
                    generated_by="fallback:heuristic",
                    provider=binding.provider_name,
                    account=binding.account_name,
                    route_reason=binding.route_reason,
                ),
            )
        ]

    def _life_admin_review(self, packet: dict[str, Any], recipe_name: str, binding: ExecutionBinding) -> list[dict[str, Any]]:
        if self._signal(packet, "life_admin_pressure") < self._adjusted_minimum_signal(packet, 0.24, 0.14):
            return []
        reminder_item = self._enrichment_item(packet, "reminders")
        calendar = self._enrichment_item(packet, "calendar")
        timing_window = self._timing_window_hint(
            calendar_item=calendar,
            reminder_item=reminder_item,
            trigger_kind=str(packet.get("triggerKind", "")).strip(),
            prefer_transition=True,
        )
        candidate_task = (
            (reminder_item or {}).get("title")
            or next((item.get("title") for item in packet.get("candidateContinuityItems", []) if item.get("title")), None)
            or "один admin-хвост"
        )
        action_steps = [
            "Сформулировать один micro-task.",
            "Привязать его к следующему transition, а не в deep work.",
            "Оставить явный done-state.",
        ]
        lines = [
            "Похоже, здесь есть life admin хвост, который лучше не держать фоном.",
            f"Самый вероятный кандидат: {candidate_task}.",
            "Это не urgent pressure, а мягкое напоминание, чтобы хвост не продолжал съедать внимание.",
        ]
        if reminder_item:
            lines.append(f"Самый явный внешний anchor из reminders: {self._enrichment_anchor(reminder_item)}.")
        elif calendar:
            lines.append(f"Есть подходящий transition anchor: {self._enrichment_anchor(calendar)}.")
        if timing_window:
            lines.append(f"Мягче всего делать это {timing_window}.")
        lines.extend(
            [
                "Если захочешь закрыть аккуратно:",
                f"1. {action_steps[0]}",
                f"2. {action_steps[1]}",
                f"3. {action_steps[2]}",
            ]
        )
        return [
            self._artifact(
                packet=packet,
                domain="life_admin",
                kind="life_admin_reminder",
                title="Тихий admin хвост просит явной фиксации",
                body="\n".join(lines),
                recipe_name=recipe_name,
                thread_id=self._primary_thread(packet).get("id") if self._primary_thread(packet) else None,
                confidence=min(0.8, 0.46 + self._signal(packet, "life_admin_pressure") * 0.3),
                why_now="Life admin лучше поднимать в transition, пока он не превращается в фоновый шум.",
                metadata_json=self._guidance_metadata(
                    summary="Quiet life admin tail detected.",
                    evidence_pack=packet.get("evidenceRefs", [])[:3],
                    action_steps=action_steps,
                    candidate_task=candidate_task,
                    pattern_name="Life Admin Reminder",
                    source_anchors=self._source_anchors(reminder_item, calendar),
                    enrichment_sources=self._enrichment_sources(reminder_item, calendar),
                    timing_window=timing_window,
                    generated_by="fallback:heuristic",
                    provider=binding.provider_name,
                    account=binding.account_name,
                    route_reason=binding.route_reason,
                ),
            )
        ]

    def _normalized_angles(self, packet: dict[str, Any]) -> list[str]:
        supported = [
            "observation",
            "contrarian_take",
            "question",
            "mini_framework",
            "lesson_learned",
            "provocation",
        ]
        raw = packet.get("constraints", {}).get("preferredAngles") or []
        allow_provocation = bool(packet.get("constraints", {}).get("allowProvocation"))
        cleaned: list[str] = []
        seen: set[str] = set()
        for angle in raw:
            value = str(angle).strip().lower()
            if not value or value not in supported:
                continue
            if not allow_provocation and value == "provocation":
                continue
            if value in seen:
                continue
            seen.add(value)
            cleaned.append(value)
        if not cleaned:
            cleaned = ["observation", "question", "lesson_learned", "mini_framework"]
        if allow_provocation and "provocation" not in cleaned:
            cleaned.append("provocation")
        return cleaned

    def _preferred_angle(self, packet: dict[str, Any], fallback: str) -> str:
        return (self._normalized_angles(packet) or [fallback])[0]

    def _alternative_angles(self, packet: dict[str, Any], primary_angle: str) -> list[str]:
        candidates = [angle for angle in self._normalized_angles(packet) if angle != primary_angle]
        if not candidates:
            candidates = [angle for angle in ["question", "lesson_learned", "mini_framework"] if angle != primary_angle]
        return candidates[:2]

    def _normalized_avoid_topics(self, packet: dict[str, Any]) -> list[str]:
        raw = packet.get("constraints", {}).get("avoidTopics") or []
        values: list[str] = []
        seen: set[str] = set()
        for topic in raw:
            value = str(topic).strip()
            if not value:
                continue
            lowered = value.lower()
            if lowered in seen:
                continue
            seen.add(lowered)
            values.append(value)
        return values

    def _matched_avoid_topic(self, packet: dict[str, Any], thread: dict[str, Any]) -> str | None:
        haystacks = [
            str(thread.get("title", "")),
            str(thread.get("summary", "")),
            " ".join(packet.get("activeEntities", [])),
            " ".join(packet.get("evidenceRefs", [])),
        ]
        for topic in self._normalized_avoid_topics(packet):
            lowered = topic.lower()
            if any(lowered in haystack.lower() for haystack in haystacks):
                return topic
        return None

    def _persona(self, packet: dict[str, Any]) -> str:
        value = str(packet.get("constraints", {}).get("contentPersonaDescription", "")).strip()
        return value or "Grounded builder voice. Specific, compact, evidence-led."

    def _guidance_metadata(
        self,
        *,
        summary: str | None = None,
        primary_angle: str | None = None,
        alternative_angles: list[str] | None = None,
        evidence_pack: list[str] | None = None,
        action_steps: list[str] | None = None,
        focus_question: str | None = None,
        continuity_anchor: str | None = None,
        open_loop: str | None = None,
        decision_text: str | None = None,
        candidate_task: str | None = None,
        note_anchor_title: str | None = None,
        note_anchor_snippet: str | None = None,
        pattern_name: str | None = None,
        source_anchors: list[str] | None = None,
        enrichment_sources: list[str] | None = None,
        timing_window: str | None = None,
        generated_by: str | None = None,
        provider: str | None = None,
        account: str | None = None,
        route_reason: str | None = None,
        cli_generation_failed: bool | None = None,
    ) -> str:
        metadata: dict[str, object] = {
            "summary": summary,
            "primaryAngle": primary_angle,
            "alternativeAngles": [str(item).strip() for item in (alternative_angles or []) if str(item).strip()],
            "evidencePack": [str(item).strip() for item in (evidence_pack or []) if str(item).strip()],
            "actionSteps": [str(item).strip() for item in (action_steps or []) if str(item).strip()],
            "focusQuestion": focus_question,
            "continuityAnchor": continuity_anchor,
            "openLoop": open_loop,
            "decisionText": decision_text,
            "candidateTask": candidate_task,
            "noteAnchorTitle": note_anchor_title,
            "noteAnchorSnippet": note_anchor_snippet,
            "patternName": pattern_name,
            "sourceAnchors": [str(item).strip() for item in (source_anchors or []) if str(item).strip()],
            "enrichmentSources": [str(item).strip() for item in (enrichment_sources or []) if str(item).strip()],
            "timingWindow": timing_window,
            "generatedBy": generated_by,
            "provider": provider,
            "account": account,
            "routeReason": route_reason,
        }
        if cli_generation_failed is not None:
            metadata["cliGenerationFailed"] = cli_generation_failed
        return json.dumps(metadata, ensure_ascii=False)

    def _writing_artifact_kind(self, packet: dict[str, Any], thread: dict[str, Any], primary_angle: str) -> str:
        trigger_kind = str(packet.get("triggerKind", "")).strip()
        voice_examples = packet.get("constraints", {}).get("twitterVoiceExamples") or []
        social_pull = self._signal(packet, "social_pull")
        thread_density = self._signal(packet, "thread_density")
        total_active_minutes = int(thread.get("totalActiveMinutes", 0) or 0)
        importance_score = float(thread.get("importanceScore", 0) or 0)

        if trigger_kind == "user_invoked_write" and (
            voice_examples
            or social_pull >= 0.32
            or primary_angle in {"contrarian_take", "provocation"}
        ):
            return "tweet_seed"
        if total_active_minutes >= 180 or importance_score >= 0.8 or thread_density >= 0.76:
            return "thread_seed"
        return "note_seed"

    def _writing_title(self, kind: str, thread: dict[str, Any]) -> str:
        title = str(thread.get("title", "эта нить"))
        if kind == "tweet_seed":
            return f"Собрать tweet seed по {title}"
        if kind == "thread_seed":
            return f"Собрать thread seed по {title}"
        return f"Собрать note seed по {title}"

    def _writing_opening(self, kind: str, thread: dict[str, Any]) -> str:
        title = str(thread.get("title", "эта нить"))
        if kind == "tweet_seed":
            return f"Из этой нити уже можно собрать tweet seed вокруг {title}, не звуча как generic content machine."
        if kind == "thread_seed":
            return f"Нить {title} уже достаточно плотная, чтобы из неё вырос thread seed, а не только короткая заметка."
        return f"Из этой нити может получиться сильный note seed вокруг {title}."

    def _tweet_opening(self, angle: str, thread: dict[str, Any], packet: dict[str, Any]) -> str:
        focus = next(iter(packet.get("activeEntities", [])[:1]), str(thread.get("title", "этой нити")))
        if angle == "contrarian_take":
            return f"Кажется, интуитивный ход в {focus} часто неверный: проблема не там, где все привыкли искать."
        if angle == "question":
            return f"Вопрос по {focus}: какой один сдвиг реально меняет результат, а не только создаёт ощущение прогресса?"
        if angle == "mini_framework":
            return "Похоже, здесь складывается простой фреймворк: signal -> decision -> return point."
        if angle == "lesson_learned":
            return f"Урок из {focus}: контекст возвращается быстрее, если оставить не просто note, а явный return point."
        if angle == "provocation":
            return f"Непопулярная мысль: в {focus} часто переоценивают сложность и недооценивают стоимость повторного входа."
        return f"Замечаю одну полезную вещь про {focus}: реальный bottleneck становится виден только когда смотришь на lived evidence дня."

    def _thread_frame(self, angle: str, thread: dict[str, Any]) -> str:
        title = str(thread.get("title", "этой нити"))
        if angle == "contrarian_take":
            return f"Где популярная интерпретация по {title} расходится с тем, что показал день."
        if angle == "question":
            return f"Какой один вопрос по {title} сейчас снимает больше всего неопределённости."
        if angle == "mini_framework":
            return f"Разложить {title} в короткий рабочий framework."
        if angle == "lesson_learned":
            return f"Что именно в {title} уже превратилось в usable lesson."
        if angle == "provocation":
            return f"Какой sharp take по {title} всё ещё остаётся grounded."
        return f"Что именно наблюдается в {title}, если убрать абстракции."

    def _writing_structure(
        self,
        kind: str,
        packet: dict[str, Any],
        thread: dict[str, Any],
        primary_angle: str,
        alternative_angles: list[str],
    ) -> list[str]:
        if kind == "tweet_seed":
            return [
                "Черновой заход:",
                self._tweet_opening(primary_angle, thread, packet),
                "Запасной заход:",
                self._tweet_opening(alternative_angles[0] if alternative_angles else "question", thread, packet),
                "Форма:",
                "1. Один тезис.",
                "2. Один evidence anchor из дня.",
                "3. Один implication или открытый вопрос.",
            ]
        if kind == "thread_seed":
            return [
                "Skeleton thread:",
                f"1. Входной тезис: {thread.get('title', 'эта нить')} неожиданно оказался важнее, чем казалось.",
                f"2. Развернуть angle: {self._thread_frame(primary_angle, thread)}.",
                "3. Дать 2-3 evidence anchors из дня.",
                "4. Закончить тем, что именно меняется в подходе дальше.",
            ]
        return [
            "Если захочешь развернуть:",
            "1. Начать с одного тезиса о том, что в этой нити оказалось неожиданным.",
            "2. Добавить 2-3 evidence anchors из сегодняшних сессий.",
            "3. Закончить тем, что эта нить меняет в подходе дальше.",
        ]

    def _writing_confidence(self, kind: str, packet: dict[str, Any], thread: dict[str, Any]) -> float:
        expression_pull = self._signal(packet, "expression_pull")
        importance_score = float(thread.get("importanceScore", 0) or 0)
        kind_lift = 0.26 if kind == "tweet_seed" else 0.30 if kind == "thread_seed" else 0.24
        return min(0.9, max(0.55, 0.5 + expression_pull * 0.24 + importance_score * 0.12 + kind_lift * 0.1))

    def _writing_why_now(self, kind: str, packet: dict[str, Any]) -> str:
        trigger_kind = str(packet.get("triggerKind", "")).strip()
        if kind == "tweet_seed":
            if trigger_kind == "user_invoked_write":
                return "Сигнал на writing был ручным, и в дне уже есть persona-shaped материал для короткого post seed."
            return "Есть social/expression pull и enough evidence, чтобы короткий seed не звучал натянуто."
        if kind == "thread_seed":
            return "Нить уже достаточно плотная по времени и evidence, чтобы выдержать не только note, но и thread."
        return "В дне уже есть материал для expression, но он ещё не распался на шум."

    def _thread_writing_artifact_kind(self, packet: dict[str, Any], thread: dict[str, Any], primary_angle: str) -> str:
        trigger_kind = str(packet.get("triggerKind", "")).strip()
        voice_examples = packet.get("constraints", {}).get("twitterVoiceExamples") or []
        total_active_minutes = int(thread.get("totalActiveMinutes", 0) or 0)
        importance_score = float(thread.get("importanceScore", 0) or 0)
        if trigger_kind == "user_invoked_write" and (
            voice_examples or primary_angle in {"contrarian_take", "provocation"}
        ):
            return "tweet_seed"
        if total_active_minutes >= 180 or importance_score >= 0.8:
            return "thread_seed"
        return "note_seed"

    def _thread_writing_opening(self, kind: str, thread: dict[str, Any]) -> str:
        title = str(thread.get("title", "эта нить"))
        if kind == "tweet_seed":
            return f"Из этой нити уже можно сделать более публичный signal по {title}, не теряя grounding."
        if kind == "thread_seed":
            return f"Нить {title} уже выдерживает thread seed, а не только короткую заметку."
        return f"Из нити {title} уже может получиться сильный note seed."

    def _thread_writing_structure(
        self,
        kind: str,
        packet: dict[str, Any],
        primary_angle: str,
        alternative_angles: list[str],
    ) -> list[str]:
        title = str((self._thread_packet_thread(packet) or {}).get("title", "эта нить"))
        if kind == "tweet_seed":
            return [
                "Черновой заход:",
                self._thread_tweet_opening(primary_angle, title),
                "Запасной заход:",
                self._thread_tweet_opening(alternative_angles[0] if alternative_angles else "question", title),
                "Форма:",
                "1. Один тезис из нити.",
                "2. Один continuity anchor.",
                "3. Один implication или вопрос.",
            ]
        if kind == "thread_seed":
            return [
                "Skeleton thread:",
                f"1. Почему нить «{title}» оказалась устойчивее, чем казалось.",
                "2. Развернуть angle через один ясный frame.",
                "3. Дать 2-3 evidence anchors из нити и её continuity items.",
                "4. Закрыть тем, что это меняет дальше.",
            ]
        return [
            "Если захочешь развернуть:",
            "1. Назвать главное наблюдение по нити.",
            "2. Подкрепить его 2 evidence anchors.",
            "3. Закончить return point или open question.",
        ]

    def _thread_tweet_opening(self, angle: str, title: str) -> str:
        if angle == "contrarian_take":
            return f"Похоже, в {title} обычно переоценивают сложность и недооценивают цену повторного входа."
        if angle == "question":
            return f"Вопрос по {title}: какой один сдвиг реально удешевляет return into context?"
        if angle == "mini_framework":
            return "Похоже, здесь складывается фрейм: thread -> return point -> signal."
        if angle == "lesson_learned":
            return f"Урок из {title}: нить держится дольше, когда у неё есть явный return point."
        if angle == "provocation":
            return f"Резкая мысль: в {title} часто путают depth с повторным прогревом одного и того же контекста."
        return f"Замечаю полезную вещь про {title}: сильный signal появляется, когда нить уже выдержала несколько входов и выходов."

    def _thread_writing_confidence(self, kind: str, packet: dict[str, Any], thread: dict[str, Any]) -> float:
        expression_pull = self._signal(packet, "expression_pull")
        importance_score = float(thread.get("importanceScore", 0) or 0)
        kind_lift = 0.26 if kind == "tweet_seed" else 0.30 if kind == "thread_seed" else 0.22
        return min(0.91, max(0.56, 0.52 + expression_pull * 0.22 + importance_score * 0.14 + kind_lift * 0.1))

    def _thread_writing_why_now(self, kind: str) -> str:
        if kind == "tweet_seed":
            return "Ты вызвал writing прямо из thread context, а значит лучше дать signal с continuity anchors, а не generic content."
        if kind == "thread_seed":
            return "Нить уже накопила достаточно времени и evidence, чтобы выдержать thread, а не только короткую заметку."
        return "Нить уже тянет на текст, но ещё не обязана становиться публичным постом."

    def _notes_enrichment(self, packet: dict[str, Any]) -> list[dict[str, Any]]:
        return self._enrichment_items(packet, "notes")

    def _enrichment_items(self, packet: dict[str, Any], source: str) -> list[dict[str, Any]]:
        enrichment = packet.get("enrichment") or {}
        for bundle in enrichment.get("bundles", []):
            if bundle.get("source") == source and bundle.get("availability") == "embedded":
                items = bundle.get("items") or []
                return [item for item in items if isinstance(item, dict)]
        return []

    def _enrichment_item(self, packet: dict[str, Any], source: str) -> dict[str, Any] | None:
        return next(iter(self._enrichment_items(packet, source)), None)

    def _enrichment_anchor(self, item: dict[str, Any]) -> str:
        label = {
            "notes": "Notes",
            "calendar": "Calendar",
            "reminders": "Reminders",
            "web_research": "Web",
            "wearable": "Wearable / Rhythm",
        }.get(str(item.get("source", "")).strip(), "Context")
        title = str(item.get("title", "")).strip() or "context item"
        snippet = self._clean_snippet(str(item.get("snippet", "")).strip(), 110)
        return f"{label}: {title}" if not snippet else f"{label}: {title} — {snippet}"

    def _source_anchors(self, *items: dict[str, Any] | None) -> list[str]:
        anchors: list[str] = []
        seen: set[str] = set()
        for item in items:
            if not item:
                continue
            anchor = self._enrichment_anchor(item)
            key = anchor.lower()
            if key in seen:
                continue
            seen.add(key)
            anchors.append(anchor)
        return anchors

    def _enrichment_sources(self, *items: dict[str, Any] | None) -> list[str]:
        sources: list[str] = []
        seen: set[str] = set()
        for item in items:
            if not item:
                continue
            source = str(item.get("source", "")).strip()
            if not source or source in seen:
                continue
            seen.add(source)
            sources.append(source)
        return sources

    def _timing_window_hint(
        self,
        *,
        calendar_item: dict[str, Any] | None,
        reminder_item: dict[str, Any] | None,
        trigger_kind: str,
        prefer_transition: bool,
    ) -> str | None:
        if reminder_item is not None:
            title = str(reminder_item.get("title", "напоминание")).strip() or "напоминание"
            return f"в следующий transition вокруг «{title}»" if prefer_transition else f"рядом с напоминанием «{title}»"
        if calendar_item is None:
            return None
        title = str(calendar_item.get("title", "календарное окно")).strip() or "календарное окно"
        if trigger_kind == "morning_resume":
            return f"до ближайшего календарного блока «{title}»"
        if trigger_kind in {"reentry_after_idle", "focus_break_natural"}:
            return f"в коротком окне рядом с «{title}»"
        return f"в следующем transition вокруг «{title}»" if prefer_transition else f"вокруг окна «{title}»"

    def _artifact(
        self,
        packet: dict[str, Any],
        domain: str,
        kind: str,
        title: str,
        body: str,
        recipe_name: str,
        thread_id: str | None,
        confidence: float,
        why_now: str,
        metadata_json: str | None = None,
    ) -> dict[str, Any]:
        evidence = packet.get("evidenceRefs", [])[:8]
        return {
            "id": None,
            "domain": domain,
            "kind": kind,
            "title": title,
            "body": body,
            "threadId": thread_id,
            "sourcePacketId": packet.get("packetId", ""),
            "sourceRecipe": recipe_name,
            "confidence": round(confidence, 4),
            "whyNow": why_now,
            "evidenceJson": json.dumps(evidence, ensure_ascii=False),
            "metadataJson": metadata_json,
            "language": packet.get("language", "ru"),
            "status": "candidate",
            "createdAt": None,
            "surfacedAt": None,
            "expiresAt": None,
        }

    def _primary_thread(self, packet: dict[str, Any]) -> dict[str, Any] | None:
        threads = packet.get("candidateThreadRefs", [])
        return threads[0] if threads else None

    def _thread_packet_thread(self, packet: dict[str, Any]) -> dict[str, Any] | None:
        thread = packet.get("thread")
        return thread if isinstance(thread, dict) else None

    def _suggested_continuations(
        self,
        thread: dict[str, Any],
        items: list[dict[str, Any]],
        sessions: list[dict[str, Any]],
    ) -> list[str]:
        options: list[str] = []
        if items:
            options.append(f"Сначала закрыть или уточнить: {items[0].get('title', 'незакрытый узел')}")
        if sessions:
            options.append(
                f"Вернуться в контекст через {sessions[0].get('appName', 'последнюю рабочую сессию')} и восстановить нить по последнему evidence."
            )
        options.append(f"Сформулировать один следующий шаг по нити «{thread.get('title', 'эта нить')}».")
        options.append("Сначала коротко зафиксировать, что уже решено, чтобы не разогревать контекст заново.")
        return options[:3]

    def _clean_snippet(self, text: str, limit: int) -> str:
        compact = " ".join(str(text or "").split())
        if len(compact) <= limit:
            return compact
        return compact[: limit - 1].rstrip() + "…"

    def _signal(self, packet: dict[str, Any], name: str) -> float:
        for signal_entry in packet.get("attentionSignals", []):
            if signal_entry.get("name") == name:
                try:
                    return float(signal_entry.get("score", 0.0))
                except (TypeError, ValueError):
                    return 0.0
        return 0.0

    def _adjusted_minimum_signal(self, packet: dict[str, Any], base: float, floor: float) -> float:
        trigger_kind = str(packet.get("triggerKind", "")).strip()
        if trigger_kind not in {"user_invoked_lost", "user_invoked_write"}:
            return base
        return max(floor, base - 0.12)

    def _why_now(self, trigger_kind: str) -> str:
        mapping = {
            "morning_resume": "Утренний вход лучше делать через continuity, а не через новую инициативу.",
            "reentry_after_idle": "После idle return важнее дешёвый вход обратно, чем новый фронт работы.",
            "user_invoked_lost": "Запрос был ручным, значит полезнее не новая идея, а лучший вход обратно.",
        }
        return mapping.get(trigger_kind, "Сейчас здесь достаточно сигнала и опоры на evidence.")


class ThreadedUnixStreamServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


class AdvisoryRequestHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        line = self.rfile.readline()
        if not line:
            return

        request_id = None
        try:
            payload = json.loads(line.decode("utf-8"))
            request_id = payload.get("id")
            method = payload.get("method")
            params = payload.get("params") or {}

            if method == "advisor.health":
                result = self.server.runtime.health(force_refresh=bool(params.get("forceRefresh")))
            elif method == "advisor.auth.checkProvider":
                account_name = str(params.get("accountName", "")).strip() or None
                result = self.server.runtime.auth_check(
                    str(params.get("providerName", "")).strip(),
                    account_name=account_name,
                    force_refresh=bool(params.get("forceRefresh")),
                )
            elif method == "advisor.accounts.list":
                result = self.server.runtime.accounts(force_refresh=bool(params.get("forceRefresh")))
            elif method == "advisor.accounts.openLogin":
                result = self.server.runtime.open_login(str(params.get("providerName", "")).strip())
            elif method == "advisor.accounts.importCurrentSession":
                account_name = str(params.get("accountName", "")).strip() or None
                result = self.server.runtime.import_current_session(
                    str(params.get("providerName", "")).strip(),
                    account_name=account_name,
                )
            elif method == "advisor.accounts.reauthorize":
                result = self.server.runtime.reauthorize(
                    str(params.get("providerName", "")).strip(),
                    str(params.get("accountName", "")).strip(),
                )
            elif method == "advisor.accounts.setLabel":
                result = self.server.runtime.set_account_label(
                    str(params.get("providerName", "")).strip(),
                    str(params.get("accountName", "")).strip(),
                    str(params.get("label", "")),
                )
            elif method == "advisor.accounts.setPreferred":
                result = self.server.runtime.set_preferred_account(
                    str(params.get("providerName", "")).strip(),
                    str(params.get("accountName", "")).strip(),
                )
            elif method == "advisor.runRecipe":
                result = self.server.runtime.run_recipe(params)
            elif method == "advisor.cancelRun":
                result = self.server.runtime.cancel_run(str(params.get("runId", "")).strip())
            else:
                raise JsonRPCMethodError(-32601, f"Unknown method: {method}")

            response = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": result,
            }
        except JsonRPCMethodError as exc:
            response = {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": exc.code,
                    "message": exc.message,
                },
            }
        except Exception as exc:  # pragma: no cover - defensive
            response = {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32099,
                    "message": str(exc),
                },
            }

        self.wfile.write(json.dumps(response, ensure_ascii=False).encode("utf-8"))
        self.wfile.write(b"\n")
        self.wfile.flush()


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
        stream=sys.stderr,
    )
    parser = argparse.ArgumentParser(description="Memograph advisory sidecar")
    parser.add_argument("--socket", required=True, help="Unix domain socket path")
    parser.add_argument("--probe-timeout-seconds", type=int, default=6)
    args = parser.parse_args()

    socket_path = Path(args.socket).expanduser()
    pidfile_path = Path(str(socket_path) + ".pid")
    socket_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        startup_delay_seconds = max(0.0, float(os.getenv("MEMOGRAPH_ADVISOR_STARTUP_DELAY_SECONDS", "0") or "0"))
    except ValueError:
        startup_delay_seconds = 0.0
    startup_delay_once_file = os.getenv("MEMOGRAPH_ADVISOR_STARTUP_DELAY_ONCE_FILE", "").strip()
    should_delay_startup = startup_delay_seconds > 0
    if should_delay_startup and startup_delay_once_file:
        delay_marker = Path(startup_delay_once_file).expanduser()
        should_delay_startup = delay_marker.exists()
        if should_delay_startup:
            try:
                delay_marker.unlink()
            except OSError:
                pass
    if should_delay_startup:
        time.sleep(startup_delay_seconds)

    if socket_path.exists():
        socket_path.unlink()

    runtime = AdvisoryRuntime(probe_timeout_seconds=args.probe_timeout_seconds)
    server = ThreadedUnixStreamServer(str(socket_path), AdvisoryRequestHandler)
    server.runtime = runtime  # type: ignore[attr-defined]

    # Write pidfile so the Swift supervisor can verify socket ownership
    try:
        pidfile_path.write_text(
            json.dumps(
                {
                    "pid": os.getpid(),
                    "socket_path": str(socket_path),
                    "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "instance_id": str(uuid.uuid4()),
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
    except OSError:
        pass

    def cleanup() -> None:
        try:
            pidfile_path.unlink(missing_ok=True)
        except OSError:
            pass
        try:
            if socket_path.exists():
                socket_path.unlink()
        except OSError:
            pass

    def shutdown(*_: Any) -> None:
        server.shutdown()

    ignore_sigterm = os.getenv("MEMOGRAPH_ADVISOR_IGNORE_SIGTERM", "").strip().lower() in {"1", "true", "yes"}
    signal.signal(signal.SIGTERM, signal.SIG_IGN if ignore_sigterm else shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
