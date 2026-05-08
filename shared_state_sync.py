#!/usr/bin/env python3
"""Sync a small, non-secret Hermes shared-state bundle through Google Drive.

This is intentionally not a filesystem mount. It packages selected Hermes state
(config, skills, memory/profile notes, hooks) into one tar.gz file named
`hermes-shared-state.tar.gz` in the configured Drive folder.

Secrets are excluded by design: .env, auth.json, Google tokens, sessions, logs,
cron job outputs, and caches are not part of the bundle.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import tarfile
import tempfile
from pathlib import Path
from typing import Iterable

BUNDLE_NAME = os.getenv("HERMES_SHARED_STATE_BUNDLE_NAME", "hermes-shared-state.tar.gz")
DEFAULT_INCLUDE_FILES = [
    "config.yaml",
    "MEMORY.md",
    "USER.md",
    "personality.md",
]
DEFAULT_INCLUDE_DIRS = [
    "skills",
    "memories",
    "hooks",
]
EXCLUDED_NAMES = {
    ".env",
    "auth.json",
    "google_token.json",
    "google_client_secret.json",
    "google_oauth_pending.json",
    "google_oauth_last_url.txt",
}
EXCLUDED_DIRS = {
    "sessions",
    "logs",
    "cron",
    "pairing",
    "workspace",
    "image_cache",
    "audio_cache",
    "__pycache__",
}
EXCLUDED_SUFFIXES = (".lock", ".tar", ".tar.gz", ".zip", ".sqlite", ".db")
SENSITIVE_YAML_KEY = re.compile(
    r"^(?P<prefix>\s*(?:api_?key|secret|token|password|authorization|cookie)[\w-]*\s*:\s*)(?P<value>.+)$",
    re.IGNORECASE,
)


def _import_google():
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from googleapiclient.discovery import build
        from googleapiclient.http import MediaFileUpload, MediaIoBaseDownload
    except Exception as exc:  # pragma: no cover - runtime diagnostic
        raise SystemExit(
            "Google API dependencies are missing. Install Hermes with the Google "
            f"Workspace extras or google-api-python-client/google-auth: {exc}"
        )
    return Request, Credentials, build, MediaFileUpload, MediaIoBaseDownload


def _hermes_home() -> Path:
    return Path(os.getenv("HERMES_HOME", "/data/.hermes")).expanduser().resolve()


def _token_path(home: Path) -> Path:
    return Path(os.getenv("GOOGLE_TOKEN_PATH", str(home / "google_token.json"))).expanduser()


def _client_secret_path(home: Path) -> Path:
    return Path(os.getenv("GOOGLE_CLIENT_SECRET_PATH", str(home / "google_client_secret.json"))).expanduser()


def _folder_id() -> str:
    folder_id = os.getenv("HERMES_WORKSPACE_DRIVE_FOLDER_ID", "").strip()
    if not folder_id:
        raise SystemExit("HERMES_WORKSPACE_DRIVE_FOLDER_ID is required for Drive sync")
    return folder_id


def _drive_service(home: Path):
    Request, Credentials, build, _MediaFileUpload, _MediaIoBaseDownload = _import_google()
    token = _token_path(home)
    client_secret = _client_secret_path(home)
    if not token.exists():
        raise SystemExit(f"Google token not found: {token}")
    data = json.loads(token.read_text())
    scopes = data.get("scopes") or data.get("scope") or None
    if isinstance(scopes, str):
        scopes = scopes.split()
    creds = Credentials.from_authorized_user_file(str(token), scopes=scopes)
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())
        token.write_text(creds.to_json())
        token.chmod(0o600)
    return build("drive", "v3", credentials=creds, cache_discovery=False)


def _iter_paths(home: Path) -> Iterable[Path]:
    for rel in DEFAULT_INCLUDE_FILES:
        p = home / rel
        if p.is_file() and p.name not in EXCLUDED_NAMES:
            yield p
    for rel in DEFAULT_INCLUDE_DIRS:
        root = home / rel
        if not root.is_dir() or root.name in EXCLUDED_DIRS:
            continue
        for p in root.rglob("*"):
            if not p.is_file():
                continue
            rel_parts = p.relative_to(home).parts
            if any(part in EXCLUDED_DIRS or part.startswith(".") for part in rel_parts):
                continue
            if p.name in EXCLUDED_NAMES or p.name.endswith(EXCLUDED_SUFFIXES):
                continue
            yield p


def _sanitize_config_yaml(text: str) -> str:
    lines: list[str] = []
    for line in text.splitlines():
        match = SENSITIVE_YAML_KEY.match(line)
        if match and "${" not in match.group("value"):
            lines.append(f"{match.group('prefix')}\"\"  # redacted by shared_state_sync")
        else:
            lines.append(line)
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def make_bundle(home: Path, out_path: Path) -> int:
    count = 0
    with tarfile.open(out_path, "w:gz") as tf:
        for p in sorted(set(_iter_paths(home))):
            arcname = p.relative_to(home).as_posix()
            if arcname == "config.yaml":
                payload = _sanitize_config_yaml(p.read_text(errors="ignore")).encode()
                info = tarfile.TarInfo(arcname)
                info.size = len(payload)
                info.mode = 0o600
                info.uid = info.gid = 0
                info.uname = info.gname = "hermes"
                tf.addfile(info, io.BytesIO(payload))
                count += 1
                continue
            info = tf.gettarinfo(str(p), arcname=arcname)
            info.uid = info.gid = 0
            info.uname = info.gname = "hermes"
            with p.open("rb") as f:
                tf.addfile(info, f)
            count += 1
    return count


def _find_bundle(service, folder_id: str) -> str | None:
    escaped_name = BUNDLE_NAME.replace("'", "\\'")
    q = (
        f"name = '{escaped_name}' and '{folder_id}' in parents and "
        "trashed = false"
    )
    res = service.files().list(
        q=q,
        fields="files(id,name,modifiedTime,size)",
        spaces="drive",
        pageSize=10,
        supportsAllDrives=True,
        includeItemsFromAllDrives=True,
    ).execute()
    files = res.get("files", [])
    if not files:
        return None
    files.sort(key=lambda f: f.get("modifiedTime", ""), reverse=True)
    return files[0]["id"]


def push(home: Path) -> None:
    _Request, _Credentials, _build, MediaFileUpload, _MediaIoBaseDownload = _import_google()
    service = _drive_service(home)
    folder_id = _folder_id()
    with tempfile.TemporaryDirectory() as td:
        bundle = Path(td) / BUNDLE_NAME
        count = make_bundle(home, bundle)
        media = MediaFileUpload(str(bundle), mimetype="application/gzip", resumable=False)
        file_id = _find_bundle(service, folder_id)
        metadata = {"name": BUNDLE_NAME}
        if file_id:
            service.files().update(
                fileId=file_id,
                media_body=media,
                fields="id,name,modifiedTime,size",
                supportsAllDrives=True,
            ).execute()
            print(f"updated {BUNDLE_NAME} in Drive folder {folder_id} with {count} files")
        else:
            metadata["parents"] = [folder_id]
            service.files().create(
                body=metadata,
                media_body=media,
                fields="id,name,modifiedTime,size",
                supportsAllDrives=True,
            ).execute()
            print(f"created {BUNDLE_NAME} in Drive folder {folder_id} with {count} files")


def _safe_members(tf: tarfile.TarFile) -> list[tarfile.TarInfo]:
    safe: list[tarfile.TarInfo] = []
    for member in tf.getmembers():
        name = member.name
        parts = Path(name).parts
        if member.islnk() or member.issym():
            continue
        if name.startswith("/") or ".." in parts:
            continue
        if any(part in EXCLUDED_DIRS or part.startswith(".") for part in parts):
            continue
        if parts and (parts[-1] in EXCLUDED_NAMES or parts[-1].endswith(EXCLUDED_SUFFIXES)):
            continue
        safe.append(member)
    return safe


def pull(home: Path, overwrite: bool = False) -> None:
    _Request, _Credentials, _build, _MediaFileUpload, MediaIoBaseDownload = _import_google()
    service = _drive_service(home)
    folder_id = _folder_id()
    file_id = _find_bundle(service, folder_id)
    if not file_id:
        print(f"no {BUNDLE_NAME} found in Drive folder {folder_id}; skipping")
        return
    request = service.files().get_media(fileId=file_id, supportsAllDrives=True)
    buf = io.BytesIO()
    downloader = MediaIoBaseDownload(buf, request)
    done = False
    while not done:
        _status, done = downloader.next_chunk()
    buf.seek(0)
    home.mkdir(parents=True, exist_ok=True)
    extracted = 0
    skipped = 0
    with tarfile.open(fileobj=buf, mode="r:gz") as tf:
        for member in _safe_members(tf):
            target = home / member.name
            if target.exists() and not overwrite:
                skipped += 1
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            tf.extract(member, path=home)
            try:
                if target.is_file():
                    target.chmod(0o600 if target.name.endswith((".yaml", ".md")) else 0o644)
            except Exception:
                pass
            extracted += 1
    print(f"pulled {BUNDLE_NAME}: extracted={extracted} skipped_existing={skipped}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["push", "pull", "pack"], help="sync action")
    parser.add_argument("--home", default=str(_hermes_home()), help="Hermes home directory")
    parser.add_argument("--output", help="output path for pack")
    parser.add_argument("--overwrite", action="store_true", help="overwrite existing local files on pull")
    args = parser.parse_args()

    home = Path(args.home).expanduser().resolve()
    if args.action == "push":
        push(home)
    elif args.action == "pull":
        pull(home, overwrite=args.overwrite)
    elif args.action == "pack":
        out = Path(args.output or BUNDLE_NAME).expanduser().resolve()
        count = make_bundle(home, out)
        print(f"packed {count} files into {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
