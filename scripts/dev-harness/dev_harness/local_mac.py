"""Minimal single-endpoint ngrok lifecycle on the owned offline harness."""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import ipaddress
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote, urlsplit

from . import cli, config, safety, local_stt, local_stt_watch, local_library


class LocalMacError(ValueError):
    """Static, credential-free diagnostics safe to show in the local terminal."""


def endpoint(value: str) -> str:
    uri = urlsplit(value.strip())
    if (
        uri.scheme != "https"
        or not uri.hostname
        or uri.username
        or uri.password
        or uri.port not in (None, 443)
        or uri.query
        or uri.fragment
        or uri.path not in ("", "/")
    ):
        raise LocalMacError("Enter an HTTPS server address without a path or credentials")
    if not re.fullmatch(r"[a-zA-Z0-9.-]+", uri.hostname) or "." not in uri.hostname:
        raise LocalMacError("Enter the HTTPS domain assigned by ngrok")
    try:
        ipaddress.ip_address(uri.hostname)
    except ValueError:
        pass
    else:
        raise LocalMacError("Enter the domain assigned by ngrok, not an IP address")
    return f"https://{uri.hostname.lower()}"


def private_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + ".new")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream)
        stream.write("\n")
    temp.replace(path)


def pairing_data(key: str) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", key):
        raise LocalMacError("Invalid access key")
    return {"version": 1, "owner_uid": "alice", "key_sha256": hashlib.sha256(key.encode()).hexdigest()}


def ngrok_port(cfg) -> int:
    # Follow the harness's existing port offset, without another public listener.
    return 4040 + cfg.backend_port - config.BACKEND_PORT


def read_config(cfg) -> dict:
    path = cfg.layout.state_root / "ngrok.json"
    if not path.is_file() or path.is_symlink() or path.stat().st_mode & 0o077:
        raise LocalMacError("Run configure in a local terminal first")
    data = json.loads(path.read_text())
    data["url"] = endpoint(data["url"])
    return data


def configure(cfg, *, rotate: bool = False, edit: bool = False) -> None:
    from .local_setup import show_frame

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise LocalMacError("Configure requires a local interactive terminal; credentials must not enter logs")
    current = cfg.layout.state_root / "ngrok.json"
    if edit and (cli._service_record(cfg, "backend") or cli._service_record(cfg, "ngrok")):
        raise LocalMacError("Stop this local stack before changing its connection")
    if not current.exists() or edit:
        existing = read_config(cfg)["url"] if current.exists() else ""
        url = endpoint(input(f"HTTPS-адрес ngrok [{existing}]: ").strip() or existing)
        token = getpass.getpass("Authtoken ngrok (скрыт; Enter — использовать сохранённый): ").strip()
        if not token:
            import yaml

            candidates = [
                cfg.layout.state_root / "ngrok-agent.yml",
                Path.home() / "Library/Application Support/ngrok/ngrok.yml",
                Path.home() / ".config/ngrok/ngrok.yml",
            ]
            for candidate in candidates:
                if candidate.is_file() and not candidate.is_symlink():
                    saved = yaml.safe_load(candidate.read_text()) or {}
                    token = saved.get("agent", {}).get("authtoken") or saved.get("authtoken") or ""
                    if token:
                        break
        if not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", token):
            raise LocalMacError("Invalid ngrok authtoken format")
        # JSON is a YAML subset accepted by the agent, with restrictive permissions.
        private_json(
            cfg.layout.state_root / "ngrok-agent.yml",
            {
                "version": "3",
                "agent": {"authtoken": token, "web_addr": f"127.0.0.1:{ngrok_port(cfg)}"},
            },
        )
        private_json(current, {"url": url})
    pairing = cfg.layout.state_root / "pairing.json"
    if pairing.exists() and not rotate:
        show_frame('ДЛЯ ПРИЛОЖЕНИЯ НА IPHONE', ['Домен: ' + read_config(cfg)['url'],
                   'Ключ: прежний, сохранённый в приложении'])
        return
    if cli._service_record(cfg, "backend") or cli._service_record(cfg, "ngrok"):
        raise LocalMacError("Stop this local stack before replacing its pairing key")
    key = secrets.token_urlsafe(32)
    private_json(pairing, pairing_data(key))
    # Deliberate one-time terminal provisioning. Never written to files or logs.
    show_frame('ДЛЯ ПРИЛОЖЕНИЯ НА IPHONE', ['Домен: ' + read_config(cfg)['url'], 'Ключ:  ' + key])
    print('Введите домен и ключ в разделе «Локальный Mac» на iPhone.')
    print('Ключ показан один раз. На Mac хранится только его проверочный хеш.')


def prepare_emulator(repo: Path) -> None:
    meta_path = repo / "node_modules/firebase-tools/lib/emulator/downloadableEmulatorInfo.json"
    meta = json.loads(meta_path.read_text())["firestore"]
    cache_dir = Path(os.environ.get("FIREBASE_EMULATORS_PATH") or Path.home() / ".cache/firebase/emulators")
    target = cache_dir / meta["downloadPathRelativeToCacheDir"]

    def valid(path):
        return (
            path.is_file()
            and path.stat().st_size == meta["expectedSize"]
            and hashlib.md5(path.read_bytes()).hexdigest() == meta["expectedChecksum"]
        )

    if valid(target):
        print("Pinned Firestore emulator verified; reuse")
        return
    url = meta["remoteUrl"]
    if not url.startswith("https://storage.googleapis.com/firebase-preview-drop/emulator/"):
        raise LocalMacError("Unexpected emulator download source")
    target.parent.mkdir(parents=True, exist_ok=True)
    part = target.with_suffix(".jar.part")
    with urllib.request.urlopen(url, timeout=30) as response, part.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
    if not valid(part):
        raise LocalMacError("Emulator archive failed upstream size/checksum verification")
    part.replace(target)
    print("Pinned Firestore emulator verified")


def check_agent(cfg) -> None:
    if not shutil.which("ngrok"):
        raise LocalMacError("ngrok is missing; run install")
    if not 1024 <= ngrok_port(cfg) <= 65535:
        raise LocalMacError("ngrok agent port is outside the supported range")
    agent_config = cfg.layout.state_root / "ngrok-agent.yml"
    if not agent_config.is_file() or agent_config.is_symlink() or agent_config.stat().st_mode & 0o077:
        raise LocalMacError("Private ngrok agent configuration is missing")
    agent = json.loads(agent_config.read_text()).get("agent", {})
    if agent.get("web_addr") != f"127.0.0.1:{ngrok_port(cfg)}":
        raise LocalMacError("Agent diagnostics must bind the owned loopback port")
    result = subprocess.run(
        ["ngrok", "config", "check", "--config", str(agent_config)], capture_output=True, timeout=15
    )
    if result.returncode:
        raise LocalMacError("ngrok configuration check failed")


def ensure_owner_profile(cfg, owner_uid: str) -> None:
    """Check live emulator state, creating only a missing paired-owner profile."""
    if cfg.local_transport != "ngrok" or cfg.provider_mode != "offline" or cfg.dev_bind_host != "127.0.0.1":
        raise LocalMacError("Owner profile preparation requires the loopback ngrok stack")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", owner_uid):
        raise LocalMacError("Invalid local owner")
    collection = f"http://{cfg.firestore_host}/v1/projects/{cfg.project_id}/databases/{cfg.database_id}/documents/users"
    url = collection + "/" + quote(owner_uid, safe="")
    headers = {"Authorization": "Bearer owner", "Content-Type": "application/json"}
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=5) as response:
            if response.status == 200:
                return
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise LocalMacError("Cannot check the local owner profile") from None
    # A stale scenario manifest cannot prove that Firestore still has the user.
    # Create is atomic and never overwrites an existing profile or its settings.
    payload = {"fields": {
        "uid": {"stringValue": owner_uid},
        "display_name": {"stringValue": "Local Mac"},
        "synthetic": {"booleanValue": True},
        "local_harness": {"booleanValue": True},
    }}
    request = urllib.request.Request(
        collection + "?documentId=" + quote(owner_uid, safe=""),
        data=json.dumps(payload).encode(), headers=headers, method="POST",
    )
    try:
        urllib.request.urlopen(request, timeout=5).close()
    except urllib.error.HTTPError as error:
        if error.code != 409:
            raise LocalMacError("Cannot prepare the local owner profile") from None
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=5) as response:
        if response.status != 200:
            raise LocalMacError("Local owner profile readiness is indeterminate")
    print("Local owner profile restored; existing data and pairing preserved")


def up(cfg) -> int:
    data = read_config(cfg)
    check_agent(cfg)
    sys.path.insert(0, str(cfg.repo_root / "backend"))
    from utils.local_transport_auth import load_pairing

    os.environ["OMI_LOCAL_PAIRING_FILE"] = str(cfg.layout.state_root / "pairing.json")
    pairing = load_pairing()
    if cli.cmd_check(argparse.Namespace()):
        return 1
    if cli.cmd_up(argparse.Namespace()):
        return 1
    ensure_owner_profile(cfg, pairing["owner_uid"])
    # Require actual readiness, not a process declaration.
    with urllib.request.urlopen(cfg.backend_url + "/v1/health", timeout=5) as response:
        if response.status != 200:
            raise LocalMacError("Backend is not ready")
    require_auth_boundary(cfg.backend_url)
    cli._start_process(
        cfg,
        "ngrok",
        [
            "ngrok",
            "http",
            cfg.backend_url,
            "--url",
            data["url"],
            "--inspect=false",
            "--config",
            str(cfg.layout.state_root / "ngrok-agent.yml"),
            "--log",
            "stdout",
            "--log-level",
            "warn",
        ],
        cwd=cfg.repo_root,
        log_name="ngrok.log",
        port=ngrok_port(cfg),
    )
    for _ in range(20):
        if cli._service_health(cfg, "ngrok")[0]:
            try:
                with urllib.request.urlopen(data["url"] + "/v1/health", timeout=5) as response:
                    if response.status == 200:
                        require_auth_boundary(data["url"])
                        print("Public HTTPS health passed; run audio-smoke to verify authenticated WSS")
                        local_stt_watch.start_if_enabled(cfg)
                        return 0
            except (OSError, urllib.error.URLError):
                pass
        time.sleep(1)
    raise LocalMacError("Tunnel readiness is indeterminate; inspect the ngrok account and owned process")


def require_auth_boundary(base_url: str) -> None:
    """Observe the live boundary; a healthy legacy dev server is insufficient."""
    for headers in ({}, {"Authorization": "Bearer " + secrets.token_urlsafe(32)}):
        request = urllib.request.Request(base_url + "/openapi.json", headers=headers)
        try:
            urllib.request.urlopen(request, timeout=5).close()
        except urllib.error.HTTPError as error:
            if error.code == 401 and json.load(error).get("detail") == "local_auth_required":
                continue
        raise LocalMacError("Live local key boundary was not verified; tunnel startup stopped")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=[
            "prepare-emulator",
            "check",
            "configure",
            "edit-connection",
            "rotate-key",
            "up",
            "status",
            "down",
            "audio-smoke",
            "transcribe",
            "auto-transcribe-on",
            "auto-transcribe-off",
            "transcription-status",
            "library",
            "start",
            "setup-check",
        ],
    )
    parser.add_argument('audio', nargs='?')
    args = parser.parse_args()
    if (args.command == 'transcribe') != (args.audio is not None):
        parser.error('transcribe requires a WAV path; other commands take no audio argument')
    try:
        repo = Path.cwd()
        if args.command == "prepare-emulator":
            prepare_emulator(repo)
            return 0
        cfg = config.load_config(repo, create_layout=args.command in {"configure", "edit-connection", "rotate-key"})
        if args.command == "check":
            if not shutil.which("ngrok"):
                raise LocalMacError("ngrok is missing; run install")
            return cli.cmd_check(argparse.Namespace())
        if args.command in {"configure", "edit-connection", "rotate-key"}:
            configure(cfg, rotate=args.command == "rotate-key", edit=args.command == "edit-connection")
        elif args.command == "up":
            return up(cfg)
        elif args.command == "status":
            return cli.cmd_status(argparse.Namespace(write_summary=False))
        elif args.command == "library":
            local_library.start(cfg)
            print(local_library.url(cfg))
        elif args.command in {"start", "setup-check"}:
            from . import local_setup
            try:
                if args.command == "setup-check":
                    local_setup.check(cfg)
                    print('Готовность Mac: проверено. Изменений не внесено.')
                    return 0
                return local_setup.run(cfg)
            except local_setup.SetupError as error:
                print(str(error), file=sys.stderr)
                return 1
        elif args.command == "down":
            return cli.cmd_down(argparse.Namespace())
        elif args.command == "transcribe":
            return local_stt.transcribe(cfg, args.audio)
        elif args.command == "auto-transcribe-on":
            return local_stt_watch.enable(cfg)
        elif args.command == "auto-transcribe-off":
            return local_stt_watch.disable(cfg)
        elif args.command == "transcription-status":
            return local_stt_watch.status(cfg)
        elif args.command == "audio-smoke":
            key = getpass.getpass("App access key (hidden): ")
            pairing_data(key)
            read_fd, write_fd = os.pipe()
            try:
                os.write(write_fd, key.encode())
                os.close(write_fd)
                env = {
                    **os.environ,
                    "OMI_AUDIO_ACCESS_KEY_FD": str(read_fd),
                    "OMI_AUDIO_BASE_URL": read_config(cfg)["url"],
                }
                return subprocess.run(
                    ["bash", "scripts/dev-harness/audio-capture-smoke.sh"], env=env, pass_fds=(read_fd,)
                ).returncode
            finally:
                os.close(read_fd)
        return 0
    except (ValueError, TypeError, OSError, KeyError, safety.SafetyError, subprocess.SubprocessError) as error:
        # Error text from external tools can contain credentials or account IDs.
        message = (
            str(error)
            if isinstance(error, (LocalMacError, local_stt.TranscriptionError))
            else f"Check prerequisites and local configuration ({type(error).__name__})"
        )
        print(f"Local Mac operation failed: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
