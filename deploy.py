#!/usr/bin/env python3
"""
Cross-platform one-shot deploy runner for NL gateway stack.
Works on Linux/macOS/Windows (where Python 3 is available).
"""

from __future__ import annotations

import importlib
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ENV_PATH = SCRIPT_DIR / ".env"
REMOTE_SCRIPT_LOCAL_PATH = SCRIPT_DIR / "scripts" / "rebuild_nl_gateway.sh"


def parse_dotenv(path: Path) -> Dict[str, str]:
    data: Dict[str, str] = {}
    if not path.exists():
        return data

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        if value and value[0] in ('"', "'") and value[-1] == value[0]:
            value = value[1:-1]

        data[key] = value

    return data


def env_get(config: Dict[str, str], key: str, default: str = "") -> str:
    return os.environ.get(key, config.get(key, default))


def as_bool(value: str, default: bool = False) -> bool:
    if not value:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def ensure_paramiko(auto_install: bool):
    try:
        return importlib.import_module("paramiko")
    except ImportError:
        if not auto_install:
            raise

        print("[setup] paramiko не найден, ставлю автоматически...", flush=True)
        subprocess.check_call([sys.executable, "-m", "pip", "install", "paramiko"])
        return importlib.import_module("paramiko")


@dataclass
class SSHConfig:
    host: str
    port: int
    user: str
    password: str
    key_path: str
    key_passphrase: str
    sudo_password: str


def build_ssh_config(config: Dict[str, str]) -> SSHConfig:
    host = env_get(config, "SSH_HOST")
    if not host:
        raise ValueError("SSH_HOST is required")

    port = int(env_get(config, "SSH_PORT", "22"))
    user = env_get(config, "SSH_USER", "root")
    password = env_get(config, "SSH_PASSWORD")
    key_path = env_get(config, "SSH_PRIVATE_KEY")
    key_passphrase = env_get(config, "SSH_KEY_PASSPHRASE")
    sudo_password = env_get(config, "SUDO_PASSWORD")

    if not password and not key_path:
        raise ValueError("Set SSH_PASSWORD or SSH_PRIVATE_KEY")

    return SSHConfig(
        host=host,
        port=port,
        user=user,
        password=password,
        key_path=key_path,
        key_passphrase=key_passphrase,
        sudo_password=sudo_password,
    )


def connect_ssh(paramiko, cfg: SSHConfig):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    kwargs = {
        "hostname": cfg.host,
        "port": cfg.port,
        "username": cfg.user,
        "timeout": 20,
        "banner_timeout": 20,
        "auth_timeout": 20,
    }

    if cfg.key_path:
        kwargs["key_filename"] = cfg.key_path
        if cfg.key_passphrase:
            kwargs["passphrase"] = cfg.key_passphrase
        if cfg.password:
            kwargs["password"] = cfg.password
    else:
        kwargs["password"] = cfg.password

    client.connect(**kwargs)
    return client


def run_streaming(client, command: str) -> Tuple[int, str]:
    transport = client.get_transport()
    if transport is None:
        raise RuntimeError("SSH transport is not available")

    chan = transport.open_session()
    chan.get_pty()
    chan.exec_command(command)

    combined: list[str] = []

    while True:
        had_data = False

        while chan.recv_ready():
            data = chan.recv(4096).decode("utf-8", errors="replace")
            print(data, end="", flush=True)
            combined.append(data)
            had_data = True

        while chan.recv_stderr_ready():
            data = chan.recv_stderr(4096).decode("utf-8", errors="replace")
            print(data, end="", flush=True)
            combined.append(data)
            had_data = True

        if chan.exit_status_ready() and not chan.recv_ready() and not chan.recv_stderr_ready():
            break

        if not had_data:
            time.sleep(0.1)

    status = chan.recv_exit_status()
    return status, "".join(combined)


def remote_env_exports(config: Dict[str, str]) -> str:
    keys = [
        "VLESS_UUID",
        "REALITY_SNI",
        "REALITY_DEST",
        "REALITY_PRIVATE_KEY",
        "REALITY_SHORT_ID",
        "HY2_SNI",
        "HY2_PASSWORD",
        "MTPROXY_TLS_DOMAIN",
        "MTPROXY_SECRET",
    ]

    parts = []
    for key in keys:
        value = env_get(config, key)
        if value:
            parts.append(f"{key}={shlex.quote(value)}")

    return " ".join(parts)


def download_summary_if_any(client, output: str, host: str, artifacts_dir: Path) -> Path | None:
    match = re.search(r"Summary saved to:\s*(/\S+)", output)
    if not match:
        return None

    remote_file = match.group(1)
    artifacts_dir.mkdir(parents=True, exist_ok=True)

    local_name = f"{host}-{Path(remote_file).name}"
    local_path = artifacts_dir / local_name

    sftp = client.open_sftp()
    try:
        sftp.get(remote_file, str(local_path))
    finally:
        sftp.close()

    return local_path


def main() -> int:
    env_path = Path(os.environ.get("ENV_FILE", str(DEFAULT_ENV_PATH))).resolve()
    config = parse_dotenv(env_path)

    auto_install = as_bool(env_get(config, "AUTO_INSTALL_PARAMIKO", "1"), default=True)
    paramiko = ensure_paramiko(auto_install)

    ssh_cfg = build_ssh_config(config)

    if not REMOTE_SCRIPT_LOCAL_PATH.exists():
        print(f"Remote script not found: {REMOTE_SCRIPT_LOCAL_PATH}")
        return 1

    remote_script_path = env_get(config, "REMOTE_SCRIPT_PATH", "/tmp/rebuild_nl_gateway.sh")
    artifacts_dir = Path(env_get(config, "LOCAL_ARTIFACTS_DIR", str(SCRIPT_DIR / "artifacts"))).resolve()

    print(f"[connect] {ssh_cfg.user}@{ssh_cfg.host}:{ssh_cfg.port}")
    client = connect_ssh(paramiko, ssh_cfg)

    try:
        sftp = client.open_sftp()
        try:
            sftp.put(str(REMOTE_SCRIPT_LOCAL_PATH), remote_script_path)
        finally:
            sftp.close()

        run_streaming(client, f"chmod +x {shlex.quote(remote_script_path)}")

        exports = remote_env_exports(config)
        exports_prefix = f"{exports} " if exports else ""

        if ssh_cfg.user == "root":
            remote_cmd = f"set -euo pipefail; {exports_prefix}bash {shlex.quote(remote_script_path)}"
        else:
            if ssh_cfg.sudo_password:
                remote_cmd = (
                    "set -euo pipefail; "
                    f"{exports_prefix}echo {shlex.quote(ssh_cfg.sudo_password)} | "
                    f"sudo -S -E bash {shlex.quote(remote_script_path)}"
                )
            else:
                remote_cmd = (
                    "set -euo pipefail; "
                    f"{exports_prefix}sudo -E bash {shlex.quote(remote_script_path)}"
                )

        print("[deploy] Starting remote provisioning...\n")
        code, output = run_streaming(client, remote_cmd)

        if code != 0:
            print(f"\n[deploy] Failed with exit code: {code}")
            return code

        local_summary = download_summary_if_any(client, output, ssh_cfg.host, artifacts_dir)
        if local_summary:
            print(f"\n[artifacts] Summary downloaded to: {local_summary}")
        else:
            print("\n[artifacts] Summary path not detected in output")

        print("[deploy] Done")
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInterrupted by user")
        raise SystemExit(130)
    except Exception as exc:
        print(f"Error: {exc}")
        raise SystemExit(1)
