"""Helpers for provider login flows, session imports, and account labels."""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


VALID_PROVIDERS = ("codex", "claude", "gemini")


def provider_source_dir(provider: str, home: Path | None = None) -> Path:
    home = home or Path.home()
    if provider == "codex":
        return home / ".codex"
    return home


def provider_has_logged_in_session(provider: str, home: Path | None = None) -> bool:
    source = provider_source_dir(provider, home)

    if provider == "codex":
        return (source / "auth.json").exists() or (source / "config.toml").exists()
    if provider == "claude":
        return (source / ".claude").exists()
    if provider == "gemini":
        return (source / ".config" / "gemini").exists() or (source / ".gemini").exists()
    raise ValueError(f"Unsupported provider: {provider}")


def provider_login_command(provider: str) -> list[str]:
    if provider == "codex":
        return ["codex", "login"]
    if provider == "claude":
        return ["claude", "auth", "login"]
    if provider == "gemini":
        return ["gemini"]
    raise ValueError(f"Unsupported provider: {provider}")


def _next_account_name(provider_dir: Path) -> str:
    existing = sorted(
        account_dir.name
        for account_dir in provider_dir.iterdir()
        if account_dir.is_dir() and account_dir.name.startswith("acc")
    )
    return f"acc{len(existing) + 1}"


def import_current_session(
    provider: str,
    profiles_dir: Path,
    home: Path | None = None,
    account_name: str | None = None,
) -> str:
    if provider not in VALID_PROVIDERS:
        raise ValueError(f"Unsupported provider: {provider}")

    home = home or Path.home()
    source = provider_source_dir(provider, home)

    if not provider_has_logged_in_session(provider, home):
        raise FileNotFoundError(f"No active {provider} session found at {source}")

    provider_dir = profiles_dir / provider
    provider_dir.mkdir(parents=True, exist_ok=True)

    name = account_name.strip() if account_name else _next_account_name(provider_dir)
    if not name.startswith("acc"):
        raise ValueError("Account name must start with 'acc'.")
    destination = provider_dir / name

    if destination.exists():
        shutil.rmtree(destination)

    if provider == "codex":
        shutil.copytree(source, destination)
        return name

    home_dir = destination / "home"
    home_dir.mkdir(parents=True, exist_ok=True)

    if provider == "claude":
        shutil.copytree(source / ".claude", home_dir / ".claude")
        return name

    for candidate in (".config/gemini", ".gemini"):
        source_path = source / candidate
        if source_path.exists():
            destination_path = home_dir / candidate
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source_path, destination_path)
            return name

    raise FileNotFoundError(f"No active {provider} session found at {source}")


def open_login_terminal(provider: str, cwd: Path | None = None) -> str:
    command = provider_login_command(provider)
    command_str = shlex.join(command)

    if sys.platform == "darwin":
        working_dir = shlex.quote(str((cwd or Path.home()).expanduser()))
        osa_command = (
            'tell application "Terminal" to activate\n'
            f'tell application "Terminal" to do script "cd {working_dir}; {command_str}"'
        )
        subprocess.Popen(["osascript", "-e", osa_command])
        return command_str

    subprocess.Popen(command, cwd=str((cwd or Path.home()).expanduser()))
    return command_str


def profile_login_environment(provider: str, profile_path: Path, real_home: Path | None = None) -> dict[str, str]:
    env: dict[str, str] = {}
    actual_home = (real_home or Path(os.environ.get("HOME", str(Path.home())))).expanduser()

    if provider == "codex":
        env["CODEX_HOME"] = str(profile_path)
        return env

    env["HOME"] = str((profile_path / "home").expanduser())
    env["PATH"] = os.environ.get("PATH", "")

    if provider == "gemini":
        nvm_dir = actual_home / ".nvm"
        if nvm_dir.exists():
            env["NVM_DIR"] = str(nvm_dir)

    return env


def open_login_terminal_for_profile(
    provider: str,
    profile_path: Path,
    cwd: Path | None = None,
    real_home: Path | None = None,
) -> str:
    command = provider_login_command(provider)
    command_str = shlex.join(command)
    env = profile_login_environment(provider, profile_path, real_home=real_home)

    if sys.platform == "darwin":
        working_dir = shlex.quote(str((cwd or real_home or Path.home()).expanduser()))
        exports = " ".join(
            f"export {key}={shlex.quote(value)};"
            for key, value in env.items()
            if value
        )
        osa_command = (
            'tell application "Terminal" to activate\n'
            f'tell application "Terminal" to do script "cd {working_dir}; {exports} {command_str}"'
        )
        subprocess.Popen(["osascript", "-e", osa_command])
        return command_str

    subprocess.Popen(
        command,
        cwd=str((cwd or real_home or Path.home()).expanduser()),
        env={**os.environ, **env},
    )
    return command_str


def _metadata_path(profiles_dir: Path) -> Path:
    return profiles_dir / ".account-metadata.json"


def load_account_metadata(profiles_dir: Path) -> dict[str, dict[str, dict[str, str]]]:
    path = _metadata_path(profiles_dir)
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {
        str(provider): {
            str(account): {
                str(key): str(value)
                for key, value in payload.items()
                if isinstance(payload, dict) and isinstance(value, str)
            }
            for account, payload in accounts.items()
            if isinstance(accounts, dict)
        }
        for provider, accounts in data.items()
    }


def save_account_metadata(
    profiles_dir: Path,
    metadata: dict[str, dict[str, dict[str, str]]],
) -> None:
    path = _metadata_path(profiles_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")


def get_account_label(profiles_dir: Path, provider: str, account_name: str) -> str:
    return (
        load_account_metadata(profiles_dir)
        .get(provider, {})
        .get(account_name, {})
        .get("label", "")
    )


def set_account_label(profiles_dir: Path, provider: str, account_name: str, label: str) -> str:
    metadata = load_account_metadata(profiles_dir)
    provider_meta = metadata.setdefault(provider, {})
    account_meta = provider_meta.setdefault(account_name, {})
    normalized = label.strip()
    if normalized:
        account_meta["label"] = normalized
    else:
        account_meta.pop("label", None)
        if not account_meta:
            provider_meta.pop(account_name, None)
    if not provider_meta:
        metadata.pop(provider, None)
    save_account_metadata(profiles_dir, metadata)
    return normalized
