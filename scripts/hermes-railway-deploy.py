#!/usr/bin/env python3
"""Interactive one-click Railway deployer for Hermes Agent.

This CLI intentionally avoids writing secrets to disk. Secret values are pushed to
Railway via `railway variable set --stdin` and OAuth providers are authenticated
inside the Railway runtime by `hermes-cloud-auth` so the /data volume owns the
cloud token store.
"""
from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPO = "qf1lzx/railway-hermes-oauth-image"
DEFAULT_DRIVE_FOLDER_ID = "10Io92h6D936VcajyNYJJ9RYFkfKYQyXV"


@dataclass(frozen=True)
class ProviderChoice:
    key: str
    label: str
    auth: str  # oauth | api_key | token
    env_var: str | None = None
    provider_name: str | None = None
    default_model: str | None = None
    base_url: str | None = None
    description: str = ""


OAUTH_PROVIDERS = [
    ProviderChoice("nous", "Nous subscription", "oauth", provider_name="nous", default_model="google/gemini-3.1-flash-lite-preview", base_url="https://inference-api.nousresearch.com/v1", description="OAuth login inside Railway; good for aux, vision, web extraction, delegation."),
    ProviderChoice("openai-codex", "OpenAI Codex subscription", "oauth", provider_name="openai-codex", default_model="openai/gpt-5.4", description="OAuth/device-code login inside Railway; strong main/chat/coding judge."),
    ProviderChoice("qwen-oauth", "Qwen OAuth", "oauth", provider_name="qwen-oauth", default_model="qwen/qwen3-coder", description="Optional OAuth provider if your Hermes build supports it."),
]

API_PROVIDERS = [
    ProviderChoice("openrouter", "OpenRouter API key", "api_key", "OPENROUTER_API_KEY", "openrouter", "anthropic/claude-sonnet-4.5", description="Best catch-all API-key fallback and model marketplace."),
    ProviderChoice("anthropic", "Anthropic API key", "api_key", "ANTHROPIC_API_KEY", "anthropic", "anthropic/claude-sonnet-4.5"),
    ProviderChoice("openai", "OpenAI API key", "api_key", "OPENAI_API_KEY", "openai", "openai/gpt-4.1"),
    ProviderChoice("gemini", "Google Gemini API key", "api_key", "GOOGLE_API_KEY", "google", "google/gemini-2.5-pro"),
    ProviderChoice("deepseek", "DeepSeek API key", "api_key", "DEEPSEEK_API_KEY", "deepseek", "deepseek/deepseek-chat"),
    ProviderChoice("xai", "xAI / Grok API key", "api_key", "XAI_API_KEY", "xai", "x-ai/grok-4"),
    ProviderChoice("groq", "Groq API key", "api_key", "GROQ_API_KEY", "groq", "openai/gpt-oss-120b"),
    ProviderChoice("mistral", "Mistral API key", "api_key", "MISTRAL_API_KEY", "mistral", "mistral-large-latest"),
    ProviderChoice("copilot", "GitHub Copilot token", "token", "COPILOT_GITHUB_TOKEN", "github-copilot", None),
]

PRESETS = {
    "subscription-duo": {
        "label": "Recommended: Codex main + Nous aux/delegation",
        "main_provider": "openai-codex",
        "main_model": "openai/gpt-5.4",
        "delegation_provider": "nous",
        "delegation_model": "moonshotai/kimi-k2.6",
        "delegation_base_url": "https://inference-api.nousresearch.com/v1",
        "aux_provider": "nous",
        "aux_model": "google/gemini-3.1-flash-lite-preview",
        "aux_base_url": "https://inference-api.nousresearch.com/v1",
    },
    "nous-all": {
        "label": "Nous-first: Nous for main, aux, and delegation",
        "main_provider": "nous",
        "main_model": "deepseek-ai/DeepSeek-V3.2",
        "delegation_provider": "nous",
        "delegation_model": "moonshotai/kimi-k2.6",
        "delegation_base_url": "https://inference-api.nousresearch.com/v1",
        "aux_provider": "nous",
        "aux_model": "google/gemini-3.1-flash-lite-preview",
        "aux_base_url": "https://inference-api.nousresearch.com/v1",
    },
    "openrouter-all": {
        "label": "OpenRouter API-key fallback for everything",
        "main_provider": "openrouter",
        "main_model": "anthropic/claude-sonnet-4.5",
        "delegation_provider": "openrouter",
        "delegation_model": "anthropic/claude-sonnet-4.5",
        "delegation_base_url": "",
        "aux_provider": "openrouter",
        "aux_model": "google/gemini-2.5-flash-lite",
        "aux_base_url": "",
    },
}

DEFAULT_TOOLS = {
    "gstack": True,
    "honcho": False,
    "gbrain": False,
    "google_drive": False,
    "browser": True,
    "mcp": False,
}


@dataclass
class DeployPlan:
    project_mode: str = "create"  # create | existing | current
    project_name: str = "hermes-agent"
    project_ref: str = ""
    environment: str = ""
    service_mode: str = "create"  # create | existing | auto
    service_name: str = "hermes"
    repo: str = DEFAULT_REPO
    volume_mount_path: str = "/data"
    railway_up: bool = True
    run_cloud_auth: bool = True
    run_smoke_tests: bool = True
    hydrate_shared_state: bool = True
    expose_domain: bool = False
    client_name: str = ""
    client_slug: str = ""
    preset: str = "subscription-duo"
    oauth_providers: list[str] = field(default_factory=lambda: ["nous", "openai-codex"])
    variables: dict[str, str] = field(default_factory=dict)
    secret_variables: dict[str, str] = field(default_factory=dict)
    tool_flags: dict[str, bool] = field(default_factory=lambda: DEFAULT_TOOLS.copy())


def color(text: str, code: str) -> str:
    if os.environ.get("NO_COLOR"):
        return text
    return f"\033[{code}m{text}\033[0m"


def heading(text: str) -> None:
    print("\n" + color(text, "1;36"))
    print(color("─" * len(text), "36"))


def note(text: str) -> None:
    print(color("• ", "36") + text)


def success(text: str) -> None:
    print(color("✓ ", "32") + text)


def warn(text: str) -> None:
    print(color("⚠ ", "33") + text)


def fail(text: str) -> None:
    print(color("✗ ", "31") + text, file=sys.stderr)


def run(cmd: list[str] | str, *, input_text: str | None = None, check: bool = True, capture: bool = False, dry_run: bool = False) -> subprocess.CompletedProcess:
    printable = cmd if isinstance(cmd, str) else " ".join(shlex_quote(c) for c in cmd)
    if dry_run:
        print(color("DRY-RUN ", "33") + printable)
        return subprocess.CompletedProcess(cmd, 0, "" if capture else None, None)
    return subprocess.run(cmd, input=input_text, text=True, check=check, stdout=subprocess.PIPE if capture else None, stderr=subprocess.PIPE if capture else None)


def shlex_quote(s: str) -> str:
    import shlex
    return shlex.quote(s)


def require_command(name: str) -> None:
    if shutil.which(name) is None:
        fail(f"Missing required command: {name}")
        if name == "railway":
            print("Install Railway CLI, then run: railway login --browserless")
        sys.exit(1)


def prompt(default: str, label: str, *, required: bool = False) -> str:
    suffix = f" [{default}]" if default else ""
    while True:
        value = input(f"{label}{suffix}: ").strip()
        if not value:
            value = default
        if value or not required:
            return value
        warn("This value is required.")


def prompt_secret(label: str, *, required: bool = False) -> str:
    while True:
        value = getpass.getpass(f"{label}: ").strip()
        if value or not required:
            return value
        warn("This secret is required.")


def yes_no(label: str, default: bool = True) -> bool:
    marker = "Y/n" if default else "y/N"
    answer = input(f"{label} [{marker}]: ").strip().lower()
    if not answer:
        return default
    return answer in {"y", "yes", "true", "1"}


def choose_one(label: str, choices: list[tuple[str, str]], default_key: str) -> str:
    print(label)
    for idx, (key, title) in enumerate(choices, 1):
        default_marker = " (default)" if key == default_key else ""
        print(f"  {idx}. {title}{default_marker}")
    while True:
        raw = input("Choose number: ").strip()
        if not raw:
            return default_key
        if raw.isdigit() and 1 <= int(raw) <= len(choices):
            return choices[int(raw) - 1][0]
        warn("Choose a valid number.")


def choose_many(label: str, choices: list[ProviderChoice], defaults: list[str]) -> list[str]:
    print(label)
    for idx, choice in enumerate(choices, 1):
        default_marker = " ✓" if choice.key in defaults else ""
        desc = f" — {choice.description}" if choice.description else ""
        print(f"  {idx}. {choice.label}{default_marker}{desc}")
    print("Enter comma-separated numbers, 'all', 'none', or press Enter for defaults.")
    while True:
        raw = input("Selection: ").strip().lower()
        if not raw:
            return defaults[:]
        if raw == "all":
            return [c.key for c in choices]
        if raw in {"none", "no"}:
            return []
        selected: list[str] = []
        ok = True
        for part in re.split(r"[,\s]+", raw):
            if not part:
                continue
            if not part.isdigit() or not (1 <= int(part) <= len(choices)):
                ok = False
                break
            selected.append(choices[int(part) - 1].key)
        if ok:
            return list(dict.fromkeys(selected))
        warn("Use numbers from the list, separated by commas.")


def maybe_validate_telegram(token: str) -> None:
    if not token:
        return
    try:
        with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/getMe", timeout=15) as response:
            data = json.loads(response.read().decode("utf-8"))
        if data.get("ok") is True:
            bot = data.get("result", {}).get("username", "unknown")
            success(f"Telegram token works (@{bot}).")
            return
    except Exception as exc:  # noqa: BLE001 - show user friendly validation failure
        raise RuntimeError(f"Telegram token validation failed: {exc}") from exc
    raise RuntimeError("Telegram rejected the bot token.")


def collect_interactive() -> DeployPlan:
    print(color("""
╭──────────────────────────────────────────────╮
│ Hermes Agent Railway One-Deploy              │
│ OAuth + API keys + Gateway + tools in one CLI │
╰──────────────────────────────────────────────╯
""", "1;35"))
    note("Secrets are pushed to Railway via stdin and are not written to this repo.")
    note("Nous/Codex OAuth is completed inside Railway so /data owns cloud tokens.")

    plan = DeployPlan()

    heading("1. Railway project/service")
    plan.project_mode = choose_one("Project target:", [
        ("create", "Create a new Railway project"),
        ("existing", "Connect/link this directory to an existing Railway project"),
        ("current", "Use the project already linked in this directory"),
    ], "create")
    if plan.project_mode == "create":
        plan.project_name = prompt(plan.project_name, "New Railway project name", required=True)
    elif plan.project_mode == "existing":
        plan.project_ref = prompt(os.environ.get("RAILWAY_PROJECT_ID", ""), "Existing Railway project ID or exact name", required=True)
        plan.environment = prompt(os.environ.get("RAILWAY_ENVIRONMENT", ""), "Environment name/ID (blank for Railway default)")
    else:
        note("Using the Railway project currently linked to this directory. If none is linked, the deployer will stop with a clear error.")

    plan.service_mode = choose_one("Service target:", [
        ("create", "Create a new service from this GitHub repo / railway up"),
        ("existing", "Connect to an existing service in the selected project"),
        ("auto", "Auto: use existing service if present, otherwise create it"),
    ], "create")
    plan.service_name = prompt(plan.service_name, "Service name or ID", required=True)
    if plan.service_mode != "existing":
        plan.repo = prompt(plan.repo, "GitHub repo to deploy", required=True)
    else:
        note("Existing-service mode will not run `railway add`; it will link/set variables/deploy to that service.")
    plan.expose_domain = yes_no("Create a Railway public domain for /health after deploy?", False)

    heading("2. Client / workspace mode")
    if yes_no("Is this for a client or separate workspace?", False):
        plan.client_name = prompt("", "Client/workspace display name", required=True)
        slug_default = re.sub(r"[^a-z0-9]+", "-", plan.client_name.lower()).strip("-")
        plan.client_slug = prompt(slug_default, "Client/workspace slug", required=True)

    heading("3. Messaging gateway")
    gateway = choose_one("Choose the primary chat interface:", [
        ("telegram", "Telegram — simplest and recommended"),
        ("discord", "Discord"),
        ("slack", "Slack"),
        ("none", "Skip for now / set variables later"),
    ], "telegram")
    if gateway == "telegram":
        token = os.environ.get("TELEGRAM_BOT_TOKEN") or prompt_secret("Telegram bot token from @BotFather", required=True)
        allowed = os.environ.get("TELEGRAM_ALLOWED_USERS") or prompt("", "Your numeric Telegram user ID from @userinfobot", required=True)
        maybe_validate_telegram(token)
        plan.secret_variables["TELEGRAM_BOT_TOKEN"] = token
        plan.variables["TELEGRAM_ALLOWED_USERS"] = allowed
        plan.variables["GATEWAY_ALLOW_ALL_USERS"] = "false"
    elif gateway == "discord":
        token = os.environ.get("DISCORD_BOT_TOKEN") or prompt_secret("Discord bot token", required=True)
        allowed = prompt(os.environ.get("DISCORD_ALLOWED_USERS", ""), "Allowed Discord user IDs (comma-separated; blank to set later)")
        plan.secret_variables["DISCORD_BOT_TOKEN"] = token
        if allowed:
            plan.variables["DISCORD_ALLOWED_USERS"] = allowed
        plan.variables["GATEWAY_ALLOW_ALL_USERS"] = "false"
    elif gateway == "slack":
        bot = os.environ.get("SLACK_BOT_TOKEN") or prompt_secret("Slack bot token (xoxb-...)", required=True)
        app = os.environ.get("SLACK_APP_TOKEN") or prompt_secret("Slack app token (xapp-...)", required=True)
        plan.secret_variables["SLACK_BOT_TOKEN"] = bot
        plan.secret_variables["SLACK_APP_TOKEN"] = app
        plan.variables["GATEWAY_ALLOW_ALL_USERS"] = "false"
    else:
        warn("No messaging platform selected. Gateway will start, but you must set platform variables later.")

    heading("4. Auth providers")
    plan.oauth_providers = choose_many("OAuth/subscription providers to bootstrap in Railway:", OAUTH_PROVIDERS, ["nous", "openai-codex"])
    api_provider_keys = choose_many("API-key providers to add now:", API_PROVIDERS, [])
    provider_by_key = {p.key: p for p in API_PROVIDERS}
    for key in api_provider_keys:
        provider = provider_by_key[key]
        env_name = provider.env_var
        assert env_name
        value = os.environ.get(env_name) or prompt_secret(f"{provider.label} ({env_name})", required=True)
        plan.secret_variables[env_name] = value

    heading("5. Model routing")
    plan.preset = choose_one("Choose a model-routing preset:", [(k, v["label"]) for k, v in PRESETS.items()], "subscription-duo")
    preset = PRESETS[plan.preset]
    plan.variables.update({
        "HERMES_MAIN_PROVIDER": preset["main_provider"],
        "HERMES_MAIN_MODEL": preset["main_model"],
        "HERMES_DELEGATION_PROVIDER": preset["delegation_provider"],
        "HERMES_DELEGATION_MODEL": preset["delegation_model"],
        "HERMES_AUX_PROVIDER": preset["aux_provider"],
        "HERMES_AUX_MODEL": preset["aux_model"],
        "HERMES_AUX_CONTEXT_LENGTH": "1048576",
    })
    if preset["delegation_base_url"]:
        plan.variables["HERMES_DELEGATION_BASE_URL"] = preset["delegation_base_url"]
    if preset["aux_base_url"]:
        plan.variables["HERMES_AUX_BASE_URL"] = preset["aux_base_url"]

    if yes_no("Customize model names/providers manually?", False):
        for key, label in [
            ("HERMES_MAIN_PROVIDER", "Main provider"),
            ("HERMES_MAIN_MODEL", "Main model"),
            ("HERMES_DELEGATION_PROVIDER", "Delegation provider"),
            ("HERMES_DELEGATION_MODEL", "Delegation model"),
            ("HERMES_AUX_PROVIDER", "Auxiliary provider"),
            ("HERMES_AUX_MODEL", "Auxiliary model"),
        ]:
            plan.variables[key] = prompt(plan.variables.get(key, ""), label, required=True)

    heading("6. Tooling and memory")
    plan.tool_flags["gstack"] = yes_no("Auto-install gstack on Railway boot?", True)
    plan.tool_flags["honcho"] = yes_no("Enable Honcho memory if you provide HONCHO_API_KEY?", False)
    if plan.tool_flags["honcho"]:
        honcho_key = os.environ.get("HONCHO_API_KEY") or prompt_secret("HONCHO_API_KEY", required=True)
        plan.secret_variables["HONCHO_API_KEY"] = honcho_key
        plan.variables["HERMES_MEMORY_PROVIDER"] = "honcho"
        plan.variables["HERMES_MEMORY_ENABLED"] = "true"
    plan.tool_flags["gbrain"] = yes_no("Add GBrain/Google Brain-style tool credentials if you have a GBRAIN_API_KEY?", False)
    if plan.tool_flags["gbrain"]:
        gbrain_key = os.environ.get("GBRAIN_API_KEY") or prompt_secret("GBRAIN_API_KEY (leave blank if this uses a different variable)")
        if gbrain_key:
            plan.secret_variables["GBRAIN_API_KEY"] = gbrain_key
        custom = prompt("", "Any additional GBrain env var as NAME=value (blank to skip)")
        if custom and "=" in custom:
            name, value = custom.split("=", 1)
            plan.secret_variables[name.strip()] = value.strip()

    plan.tool_flags["google_drive"] = yes_no("Sync non-secret Hermes shared state through Google Drive API?", not bool(plan.client_name))
    if plan.tool_flags["google_drive"]:
        default_folder = "" if plan.client_name else DEFAULT_DRIVE_FOLDER_ID
        folder = prompt(default_folder, "Google Drive folder ID for hermes-shared-state.tar.gz", required=True)
        plan.variables["HERMES_WORKSPACE_DRIVE_FOLDER_ID"] = folder
        plan.variables["HERMES_SHARED_STATE_SYNC"] = "drive"
        plan.variables["HERMES_SHARED_STATE_PULL_OVERWRITE"] = "true"
        token_path = Path(prompt(str(Path.home() / ".hermes/google_token.json"), "Local google_token.json path"))
        secret_path = Path(prompt(str(Path.home() / ".hermes/google_client_secret.json"), "Local google_client_secret.json path"))
        if token_path.is_file():
            plan.secret_variables["GOOGLE_TOKEN_JSON"] = token_path.read_text()
        else:
            warn(f"Google token not found: {token_path}. Set GOOGLE_TOKEN_JSON later if Drive sync should work.")
        if secret_path.is_file():
            plan.secret_variables["GOOGLE_CLIENT_SECRET_JSON"] = secret_path.read_text()
        else:
            warn(f"Google client secret not found: {secret_path}. Set GOOGLE_CLIENT_SECRET_JSON later if Drive sync should work.")
    else:
        plan.variables["HERMES_SHARED_STATE_SYNC"] = "none"
        plan.hydrate_shared_state = yes_no("Hydrate local non-secret Hermes state directly over Railway SSH after deploy?", True)

    plan.variables.update({
        "HERMES_OAUTH_PROVIDERS": ",".join(plan.oauth_providers),
        "GSTACK_AUTO_SETUP": "true" if plan.tool_flags["gstack"] else "false",
        "GSTACK_HOSTS": prompt("codex,claude", "gstack hosts", required=True) if plan.tool_flags["gstack"] else "",
        "GSTACK_TEAM_MODE": "false",
        "GSTACK_SKILL_PREFIX": "false",
        "GSTACK_PLAYWRIGHT_BROWSERS_PATH": "/tmp/ms-playwright",
        "GSTACK_CLEAN_PLAYWRIGHT_CACHE": "true",
        "HERMES_REDACT_SECRETS": "true",
    })
    if plan.client_name:
        plan.variables["CLIENT_NAME"] = plan.client_name
        plan.variables["CLIENT_SLUG"] = plan.client_slug

    heading("7. Finish")
    plan.run_cloud_auth = bool(plan.oauth_providers) and yes_no("Run cloud OAuth helper over Railway SSH after deployment?", True)
    plan.run_smoke_tests = yes_no("Run a post-deploy Hermes smoke test?", True)
    return plan


def apply_env_overrides(plan: DeployPlan) -> DeployPlan:
    for attr, env_name in [
        ("project_mode", "RAILWAY_PROJECT_MODE"),
        ("project_name", "PROJECT_NAME"),
        ("project_ref", "RAILWAY_PROJECT_ID"),
        ("project_ref", "RAILWAY_PROJECT"),
        ("environment", "RAILWAY_ENVIRONMENT"),
        ("service_mode", "RAILWAY_SERVICE_MODE"),
        ("service_name", "SERVICE_NAME"),
        ("service_name", "RAILWAY_SERVICE_ID"),
        ("repo", "REPO"),
        ("volume_mount_path", "VOLUME_MOUNT_PATH"),
    ]:
        if os.environ.get(env_name):
            setattr(plan, attr, os.environ[env_name])
    for key in [
        "TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS", "DISCORD_BOT_TOKEN", "SLACK_BOT_TOKEN", "SLACK_APP_TOKEN",
        "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY",
        "DEEPSEEK_API_KEY", "XAI_API_KEY", "GROQ_API_KEY", "MISTRAL_API_KEY", "HONCHO_API_KEY", "GBRAIN_API_KEY",
    ]:
        if os.environ.get(key):
            if key.endswith("TOKEN") or key.endswith("KEY"):
                plan.secret_variables[key] = os.environ[key]
            else:
                plan.variables[key] = os.environ[key]
    return plan


def validate_plan(plan: DeployPlan) -> None:
    if plan.project_mode not in {"create", "existing", "current"}:
        raise SystemExit(f"Invalid RAILWAY_PROJECT_MODE={plan.project_mode!r}; use create, existing, or current")
    if plan.service_mode not in {"create", "existing", "auto"}:
        raise SystemExit(f"Invalid RAILWAY_SERVICE_MODE={plan.service_mode!r}; use create, existing, or auto")
    if plan.project_mode == "existing" and not plan.project_ref:
        raise SystemExit("RAILWAY_PROJECT_MODE=existing requires RAILWAY_PROJECT_ID or RAILWAY_PROJECT")
    if not plan.service_name:
        raise SystemExit("SERVICE_NAME or RAILWAY_SERVICE_ID is required")


def print_plan(plan: DeployPlan, *, dry_run: bool) -> None:
    heading("Deployment plan")
    project_display = plan.project_name if plan.project_mode == "create" else (plan.project_ref or "current link")
    print(f"Project:  {project_display} ({plan.project_mode})")
    if plan.environment:
        print(f"Env:      {plan.environment}")
    print(f"Service:  {plan.service_name} ({plan.service_mode})")
    print(f"Repo:     {plan.repo if plan.service_mode != 'existing' else 'existing service'}")
    print(f"Volume:   {plan.volume_mount_path}")
    print(f"Preset:   {PRESETS.get(plan.preset, {}).get('label', plan.preset)}")
    print(f"OAuth:    {', '.join(plan.oauth_providers) or 'none'}")
    print(f"Tools:    " + ", ".join(k for k, v in plan.tool_flags.items() if v))
    print(f"Vars:     {len(plan.variables)} plain, {len(plan.secret_variables)} secret")
    if dry_run:
        warn("Dry run: no Railway changes will be made.")


def railway_json(cmd: list[str]) -> object | None:
    try:
        cp = subprocess.run(cmd, text=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return json.loads(cp.stdout)
    except Exception:
        return None


def service_exists(service_name: str) -> bool:
    data = railway_json(["railway", "service", "list", "--json"])
    if isinstance(data, list):
        return any(item.get("name") == service_name or item.get("id") == service_name for item in data if isinstance(item, dict))
    # fallback for older CLI formats
    cp = subprocess.run(["railway", "service", "list"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return service_name in cp.stdout


def volume_exists(mount_path: str) -> bool:
    data = railway_json(["railway", "volume", "list", "--json"])
    if isinstance(data, list):
        return any(item.get("mountPath") == mount_path for item in data if isinstance(item, dict))
    cp = subprocess.run(["railway", "volume", "list"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return mount_path in cp.stdout


def set_railway_var(service: str, name: str, value: str, *, secret: bool, dry_run: bool) -> None:
    if value == "":
        return
    if dry_run:
        shown = "<secret>" if secret else value
        print(color("DRY-RUN ", "33") + f"railway variable set --service {service} {name}={shown}")
        return
    subprocess.run(["railway", "variable", "set", "--service", service, "--skip-deploys", "--stdin", name], input=value, text=True, check=True, stdout=subprocess.DEVNULL)
    print(f"set {name}{' (secret)' if secret else ''}")


def wait_for_ssh(service: str, *, dry_run: bool) -> bool:
    if dry_run:
        print(color("DRY-RUN ", "33") + f"wait for railway ssh --service {service}")
        return True
    for attempt in range(1, 31):
        cp = subprocess.run(["railway", "ssh", "--service", service, "echo ssh_ready"], text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if cp.returncode == 0:
            return True
        print(f"Waiting for Railway SSH/deployment ({attempt}/30)...")
        import time
        time.sleep(10)
    return False


def hydrate_shared_state(plan: DeployPlan, *, dry_run: bool) -> None:
    if not plan.hydrate_shared_state:
        return
    sync_py = ROOT / "shared_state_sync.py"
    if not sync_py.exists():
        warn("shared_state_sync.py not found; skipping direct state hydration.")
        return
    if dry_run:
        print(color("DRY-RUN ", "33") + "pack local shared state and stream into Railway /data/.hermes")
        return
    with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        subprocess.run([sys.executable, str(sync_py), "pack", "--home", os.environ.get("LOCAL_HERMES_HOME", str(Path.home() / ".hermes")), "--output", str(tmp_path)], check=True)
        data = subprocess.check_output(["base64", str(tmp_path)], text=True)
        remote = "export HOME=/data HERMES_HOME=/data/.hermes; tmp=$(mktemp /tmp/hermes-shared-state.XXXXXX.tar.gz); base64 -d > \"$tmp\"; mkdir -p \"$HERMES_HOME\"; tar -xzf \"$tmp\" -C \"$HERMES_HOME\"; rm -f \"$tmp\"; echo hydrated shared state"
        subprocess.run(["railway", "ssh", "--service", plan.service_name, remote], input=data, text=True, check=True)
    finally:
        tmp_path.unlink(missing_ok=True)


def deploy(plan: DeployPlan, *, dry_run: bool) -> None:
    require_command("railway")
    require_command("git")
    require_command("python")

    if not dry_run:
        cp = subprocess.run(["railway", "whoami"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if cp.returncode != 0:
            fail("Railway CLI is not logged in. Run: railway login --browserless")
            sys.exit(1)

    heading("Creating/linking Railway project")
    if plan.project_mode == "current":
        if dry_run:
            print(color("DRY-RUN ", "33") + "verify current directory is linked with railway status")
        else:
            cp = subprocess.run(["railway", "status"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if cp.returncode != 0:
                fail("This directory is not linked to a Railway project. Re-run and choose create or existing, or run `railway link` first.")
                sys.exit(1)
            success("Using currently linked Railway project.")
    elif plan.project_mode == "existing":
        cmd = ["railway", "link", "--project", plan.project_ref]
        if plan.environment:
            cmd += ["--environment", plan.environment]
        run(cmd, dry_run=dry_run)
    else:
        run(["railway", "init", "--name", plan.project_name], dry_run=dry_run)

    heading("Ensuring service and volume")
    exists = False if dry_run else service_exists(plan.service_name)
    if plan.service_mode == "existing":
        if dry_run:
            print(color("DRY-RUN ", "33") + f"railway service link {plan.service_name}")
        elif not exists:
            fail(f"Service not found in selected project/environment: {plan.service_name}")
            print("Use service_mode=create/auto to create it, or check `railway service list --json`.", file=sys.stderr)
            sys.exit(1)
        else:
            run(["railway", "service", "link", plan.service_name], dry_run=dry_run)
            success(f"Linked existing service: {plan.service_name}")
    elif plan.service_mode == "auto" and exists:
        run(["railway", "service", "link", plan.service_name], check=False, dry_run=dry_run)
        success(f"Using existing service: {plan.service_name}")
    else:
        try:
            run(["railway", "add", "--repo", plan.repo, "--service", plan.service_name], dry_run=dry_run)
        except subprocess.CalledProcessError:
            warn("GitHub-backed service add failed; falling back to empty service + railway up.")
            run(["railway", "add", "--service", plan.service_name], dry_run=dry_run)
        run(["railway", "service", "link", plan.service_name], check=False, dry_run=dry_run)
    if dry_run or not volume_exists(plan.volume_mount_path):
        run(["railway", "volume", "add", "--mount-path", plan.volume_mount_path], dry_run=dry_run)
    else:
        success(f"Volume exists at {plan.volume_mount_path}")

    heading("Setting Railway variables")
    for name, value in sorted(plan.variables.items()):
        set_railway_var(plan.service_name, name, value, secret=False, dry_run=dry_run)
    for name, value in sorted(plan.secret_variables.items()):
        set_railway_var(plan.service_name, name, value, secret=True, dry_run=dry_run)

    if plan.tool_flags.get("google_drive") and plan.variables.get("HERMES_SHARED_STATE_SYNC") == "drive" and "GOOGLE_TOKEN_JSON" in plan.secret_variables:
        heading("Publishing shared state to Drive")
        if dry_run:
            print(color("DRY-RUN ", "33") + "scripts/publish-shared-state-to-drive.sh")
        else:
            env = os.environ.copy()
            env["HERMES_WORKSPACE_DRIVE_FOLDER_ID"] = plan.variables["HERMES_WORKSPACE_DRIVE_FOLDER_ID"]
            subprocess.run([str(ROOT / "scripts/publish-shared-state-to-drive.sh")], env=env, check=False)

    heading("Deploying")
    if plan.railway_up:
        run(["railway", "up", "--service", plan.service_name, "--detach"], dry_run=dry_run)

    if plan.hydrate_shared_state:
        heading("Hydrating local shared Hermes state")
        if wait_for_ssh(plan.service_name, dry_run=dry_run):
            hydrate_shared_state(plan, dry_run=dry_run)
        else:
            warn("Railway SSH did not become ready; skipping direct hydration.")

    if plan.run_cloud_auth and plan.oauth_providers:
        heading("Cloud OAuth")
        if wait_for_ssh(plan.service_name, dry_run=dry_run):
            providers = ",".join(plan.oauth_providers)
            run(["railway", "ssh", "--service", plan.service_name, f"export HOME=/data HERMES_HOME=/data/.hermes HERMES_OAUTH_PROVIDERS={shlex_quote(providers)}; hermes-cloud-auth"], dry_run=dry_run)
            run(["railway", "restart", "--service", plan.service_name, "--yes"], check=False, dry_run=dry_run)
        else:
            warn("Railway SSH did not become ready; run cloud OAuth later: railway ssh --service hermes && hermes-cloud-auth")

    if plan.run_smoke_tests:
        heading("Smoke test")
        if wait_for_ssh(plan.service_name, dry_run=dry_run):
            run(["railway", "ssh", "--service", plan.service_name, "export HOME=/data HERMES_HOME=/data/.hermes; timeout 180 hermes chat -q 'Reply with exactly RAILWAY_OK' --quiet --toolsets ''"], check=False, dry_run=dry_run)

    if plan.expose_domain:
        heading("Public health domain")
        run(["railway", "domain", "--service", plan.service_name, "--port", "8080"], check=False, dry_run=dry_run)

    heading("Done")
    print(textwrap.dedent(f"""
    Hermes Railway deploy flow finished.

    Useful commands:
      railway status
      railway logs --service {plan.service_name} --lines 100
      railway ssh --service {plan.service_name}
      railway restart --service {plan.service_name}

    If OAuth was skipped or failed:
      railway ssh --service {plan.service_name}
      export HOME=/data HERMES_HOME=/data/.hermes HERMES_OAUTH_PROVIDERS={','.join(plan.oauth_providers) or 'nous,openai-codex'}
      hermes-cloud-auth
    """).strip())


def main() -> int:
    parser = argparse.ArgumentParser(description="Interactive one-click Railway deployer for Hermes Agent")
    parser.add_argument("--dry-run", action="store_true", help="Show actions without touching Railway")
    parser.add_argument("--yes", action="store_true", help="Use environment/default values without prompts")
    parser.add_argument("--no-cloud-auth", action="store_true", help="Deploy but do not run hermes-cloud-auth over Railway SSH")
    parser.add_argument("--no-smoke-test", action="store_true", help="Skip post-deploy hermes chat smoke test")
    args = parser.parse_args()

    if args.yes:
        plan = apply_env_overrides(DeployPlan())
        preset = PRESETS[plan.preset]
        plan.variables.update({
            "HERMES_MAIN_PROVIDER": os.environ.get("HERMES_MAIN_PROVIDER", preset["main_provider"]),
            "HERMES_MAIN_MODEL": os.environ.get("HERMES_MAIN_MODEL", preset["main_model"]),
            "HERMES_DELEGATION_PROVIDER": os.environ.get("HERMES_DELEGATION_PROVIDER", preset["delegation_provider"]),
            "HERMES_DELEGATION_MODEL": os.environ.get("HERMES_DELEGATION_MODEL", preset["delegation_model"]),
            "HERMES_AUX_PROVIDER": os.environ.get("HERMES_AUX_PROVIDER", preset["aux_provider"]),
            "HERMES_AUX_MODEL": os.environ.get("HERMES_AUX_MODEL", preset["aux_model"]),
            "HERMES_OAUTH_PROVIDERS": os.environ.get("HERMES_OAUTH_PROVIDERS", ",".join(plan.oauth_providers)),
            "GSTACK_AUTO_SETUP": os.environ.get("GSTACK_AUTO_SETUP", "true"),
            "GSTACK_HOSTS": os.environ.get("GSTACK_HOSTS", "codex,claude"),
            "GSTACK_PLAYWRIGHT_BROWSERS_PATH": os.environ.get("GSTACK_PLAYWRIGHT_BROWSERS_PATH", "/tmp/ms-playwright"),
            "GSTACK_CLEAN_PLAYWRIGHT_CACHE": os.environ.get("GSTACK_CLEAN_PLAYWRIGHT_CACHE", "true"),
            "HERMES_SHARED_STATE_SYNC": os.environ.get("HERMES_SHARED_STATE_SYNC", "none"),
            "GATEWAY_ALLOW_ALL_USERS": os.environ.get("GATEWAY_ALLOW_ALL_USERS", "false"),
            "HERMES_REDACT_SECRETS": "true",
        })
        if preset["delegation_base_url"]:
            plan.variables["HERMES_DELEGATION_BASE_URL"] = preset["delegation_base_url"]
        if preset["aux_base_url"]:
            plan.variables["HERMES_AUX_BASE_URL"] = preset["aux_base_url"]
        plan.run_cloud_auth = not args.no_cloud_auth
        plan.run_smoke_tests = not args.no_smoke_test
    else:
        plan = collect_interactive()
        if args.no_cloud_auth:
            plan.run_cloud_auth = False
        if args.no_smoke_test:
            plan.run_smoke_tests = False

    validate_plan(plan)
    print_plan(plan, dry_run=args.dry_run)
    if not args.yes and not yes_no("Proceed?", True):
        warn("Cancelled.")
        return 1
    deploy(plan, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
