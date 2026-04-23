#!/bin/bash
# ============================================================
# deploy.sh - Universal project deployer via Cloudflare Tunnel
# ============================================================

set -euo pipefail

SCRIPT_VERSION="per-deploy-tunnel-v3-auto-restart"
AUTO_RESTART_AFTER_MINUTES="50"

PROJECT_NAME=""
PROJECT_TYPE=""
BUILD_CMD=""
START_CMD=""
PORT=""
HOST_NAME=""
SERVER_ID=""
REPO_URL=""
BRANCH=""
COMMIT=""
ENV_VARS_JSON="[]"
CF_TOKEN=""
ZONE_ID=""
ACCOUNT_ID=""
TUNNEL_TOKEN=""
SUPA_URL=""
SUPA_KEY=""
DB_DATABASE_TYPE="none"
DB_DATABASE_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name) PROJECT_NAME="$2"; shift 2 ;;
    --type)         PROJECT_TYPE="$2"; shift 2 ;;
    --build)        BUILD_CMD="$2"; shift 2 ;;
    --start)        START_CMD="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --host-name)    HOST_NAME="$2"; shift 2 ;;
    --server-id)    SERVER_ID="$2"; shift 2 ;;
    --repo-url)     REPO_URL="$2"; shift 2 ;;
    --branch)       BRANCH="$2"; shift 2 ;;
    --commit)       COMMIT="$2"; shift 2 ;;
    --env-vars)     ENV_VARS_JSON="$2"; shift 2 ;;
    --cf-token)     CF_TOKEN="$2"; shift 2 ;;
    --zone-id)      ZONE_ID="$2"; shift 2 ;;
    --account-id)   ACCOUNT_ID="$2"; shift 2 ;;
    --tunnel-token) TUNNEL_TOKEN="$2"; shift 2 ;;
    --supa-url)     SUPA_URL="$2"; shift 2 ;;
    --supa-key)     SUPA_KEY="$2"; shift 2 ;;
    --database-type) DB_DATABASE_TYPE="$2"; shift 2 ;;
    --database-url)  DB_DATABASE_URL="$2"; shift 2 ;;
    *)
      echo "[ERROR] Unknown parameter: $1"
      exit 1
      ;;
  esac
done

MISSING=""
[[ -z "$PROJECT_NAME" ]] && MISSING="$MISSING --project-name"
[[ -z "$PROJECT_TYPE" ]] && MISSING="$MISSING --type"
[[ -z "$BUILD_CMD" ]] && MISSING="$MISSING --build"
[[ -z "$START_CMD" ]] && MISSING="$MISSING --start"
[[ -z "$PORT" ]] && MISSING="$MISSING --port"
[[ -z "$HOST_NAME" ]] && MISSING="$MISSING --host-name"
[[ -z "$REPO_URL" ]] && MISSING="$MISSING --repo-url"
[[ -z "$CF_TOKEN" ]] && MISSING="$MISSING --cf-token"
[[ -z "$ZONE_ID" ]] && MISSING="$MISSING --zone-id"
[[ -z "$ACCOUNT_ID" ]] && MISSING="$MISSING --account-id"
[[ -z "$SUPA_URL" ]] && MISSING="$MISSING --supa-url"
[[ -z "$SUPA_KEY" ]] && MISSING="$MISSING --supa-key"

if [[ -n "$MISSING" ]]; then
  echo "[ERROR] Missing required parameters:$MISSING"
  exit 1
fi

case "$PROJECT_TYPE" in
  python|node)
    ;;
  *)
    echo "[ERROR] Unsupported project type: $PROJECT_TYPE"
    echo "Supported types: python, node"
    exit 1
    ;;
esac

echo ""
echo "=========================================="
echo " Deploying: $PROJECT_NAME"
echo "=========================================="
echo "  script    : $SCRIPT_VERSION"
echo "  type      : $PROJECT_TYPE"
echo "  build     : $BUILD_CMD"
echo "  start     : $START_CMD"
echo "  port      : $PORT"
echo "  host      : $HOST_NAME"
echo "  repo      : $REPO_URL"
[[ -n "$BRANCH" ]] && echo "  branch    : $BRANCH"
[[ -n "$COMMIT" ]] && echo "  commit    : $COMMIT"
[[ "$ENV_VARS_JSON" != "[]" && -n "$ENV_VARS_JSON" ]] && echo "  env vars  : configured"
[[ "$DB_DATABASE_TYPE" != "none" && -n "$DB_DATABASE_TYPE" ]] && echo "  database  : $DB_DATABASE_TYPE"
echo "=========================================="
echo ""

APP_DIR="/tmp/$PROJECT_NAME"

echo "[DEPLOY] Cloning $REPO_URL into $APP_DIR ..."
rm -rf "$APP_DIR"
if [[ -n "$BRANCH" ]]; then
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$APP_DIR"
else
  git clone "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR"

if [[ -n "$COMMIT" ]]; then
  echo "[DEPLOY] Checking out commit $COMMIT ..."
  git fetch --depth 1 origin "$COMMIT" || git fetch origin "$COMMIT"
  git checkout --detach "$COMMIT"
fi

WORKING_COMMIT_ID="$(git rev-parse HEAD 2>/dev/null || true)"
if [[ -n "$WORKING_COMMIT_ID" ]]; then
  echo "[DEPLOY] Working commit: $WORKING_COMMIT_ID"
fi

if [[ -n "$ENV_VARS_JSON" && "$ENV_VARS_JSON" != "[]" ]]; then
  echo "[DEPLOY] Exporting environment variables ..."
  while IFS= read -r env_line; do
    export "$env_line"
  done < <(
    ENV_VARS_JSON="$ENV_VARS_JSON" python3 - <<'PY'
import json
import os
import re
import shlex
import sys

try:
    env_vars = json.loads(os.environ.get("ENV_VARS_JSON") or "[]")
except json.JSONDecodeError as exc:
    print(f"[ERROR] Invalid env vars JSON: {exc}", file=sys.stderr)
    sys.exit(1)

for item in env_vars:
    if not isinstance(item, dict):
        continue
    key = str(item.get("key") or "").strip()
    if not key:
        continue
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
        print(f"[ERROR] Invalid environment variable name: {key}", file=sys.stderr)
        sys.exit(1)
    value = "" if item.get("value") is None else str(item.get("value"))
    print(f"{key}={shlex.quote(value)}")
PY
  )
fi

echo "[DEPLOY] Preparing runtime for type: $PROJECT_TYPE ..."
case "$PROJECT_TYPE" in
  python)
    command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 is required"; exit 1; }
    ;;
  node)
    command -v node >/dev/null 2>&1 || { echo "[ERROR] node is required"; exit 1; }
    command -v npm >/dev/null 2>&1 || { echo "[ERROR] npm is required"; exit 1; }
    ;;
esac

echo "[DEPLOY] Downloading cloudflared ..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /tmp/cloudflared
chmod +x /tmp/cloudflared

export PROJECT_NAME PROJECT_TYPE BUILD_CMD START_CMD PORT HOST_NAME SERVER_ID REPO_URL BRANCH APP_DIR ENV_VARS_JSON COMMIT WORKING_COMMIT_ID AUTO_RESTART_AFTER_MINUTES DB_DATABASE_TYPE DB_DATABASE_URL
export CF_TOKEN ZONE_ID ACCOUNT_ID TUNNEL_TOKEN SUPA_URL SUPA_KEY

python3 - <<'PY'
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PROJECT_NAME = os.environ["PROJECT_NAME"]
PROJECT_TYPE = os.environ["PROJECT_TYPE"]
BUILD_CMD = os.environ["BUILD_CMD"]
START_CMD = os.environ["START_CMD"]
PORT = str(os.environ["PORT"])
HOST_NAME = os.environ["HOST_NAME"]
SERVER_ID = (os.environ.get("SERVER_ID") or "").strip()
REPO_URL = os.environ["REPO_URL"]
BRANCH = (os.environ.get("BRANCH") or "").strip()
APP_DIR = os.environ["APP_DIR"]
ENV_VARS_JSON = os.environ.get("ENV_VARS_JSON") or "[]"
REQUESTED_COMMIT = (os.environ.get("COMMIT") or "").strip()
WORKING_COMMIT_ID = (os.environ.get("WORKING_COMMIT_ID") or "").strip()
AUTO_RESTART_AFTER_MINUTES = int(os.environ.get("AUTO_RESTART_AFTER_MINUTES") or "50")
AUTO_RESTART_AFTER_SECONDS = AUTO_RESTART_AFTER_MINUTES * 60

def get_env(name: str, default: str = "") -> str:
    value = (os.environ.get(name) or "").strip()
    return value if value else default


def require_env(name: str) -> str:
    value = get_env(name)
    if value:
        return value
    raise RuntimeError(f"Missing required environment variable: {name}")


CF_TOKEN = require_env("CF_TOKEN")
ZONE_ID = require_env("ZONE_ID")
ACCOUNT_ID = require_env("ACCOUNT_ID")
TUNNEL_TOKEN = get_env("TUNNEL_TOKEN")
SUPA_URL = require_env("SUPA_URL")
SUPA_KEY = require_env("SUPA_KEY")
LOCAL_URL = f"http://127.0.0.1:{PORT}"

app_proc = None
tunnel_proc = None
build_proc = None
mongo_proc = None
auto_restart_queued = False
boot_epoch = time.time()
ACTIVE_TUNNEL_ID = ""
ACTIVE_TUNNEL_TOKEN = ""
runtime_logs_lock = threading.Lock()
runtime_log_state = {
    "deployment_id": WORKING_COMMIT_ID or REQUESTED_COMMIT or "",
    "status": "building",
    "started_at": "",
    "ready_at": "",
    "failed_at": "",
    "build_command": BUILD_CMD,
    "start_command": START_CMD,
    "build_exit_code": None,
    "build": [],
    "start": [],
}
last_runtime_log_persist = 0.0
MAX_RUNTIME_LOG_LINES = 500
RUNTIME_LOG_FLUSH_INTERVAL_SECONDS = 2.0


def load_runtime_env_vars():
    try:
        env_vars = json.loads(ENV_VARS_JSON)
    except json.JSONDecodeError:
        return []

    normalized = []
    for item in env_vars or []:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key") or "").strip()
        if not key:
            continue
        normalized.append({
            "key": key,
            "value": "" if item.get("value") is None else str(item.get("value")),
        })
    return normalized


RUNTIME_ENV_VARS = load_runtime_env_vars()
DATABASE_TYPE = (os.environ.get("DB_DATABASE_TYPE") or "none").strip().lower()
MONGODB_URI = (os.environ.get("DB_DATABASE_URL") or "").strip()
if DATABASE_TYPE in {"mongo", "mongodb"} and not MONGODB_URI:
    MONGODB_URI = "mongodb://localhost:27017/"


def now():
    return datetime.now(timezone.utc).isoformat()


def classify_log_line(line: str) -> str:
    lowered = (line or "").lower()
    if any(token in lowered for token in ["error", "failed", "traceback", "exception"]):
        return "error"
    if any(token in lowered for token in ["warn", "deprecated"]):
        return "warning"
    if any(token in lowered for token in ["success", "ready", "running", "listening", "serving"]):
        return "success"
    return "info"


def strip_ansi(value: str) -> str:
    return re.sub(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])", "", value or "")


def persist_runtime_logs(force: bool = False):
    global last_runtime_log_persist
    current_time = time.time()
    if not force and current_time - last_runtime_log_persist < RUNTIME_LOG_FLUSH_INTERVAL_SECONDS:
        return

    with runtime_logs_lock:
        payload = json.loads(json.dumps(runtime_log_state))

    try:
        supa_request("PATCH", server_filter(), {
            "runtime_logs": payload,
            "last_checked": now(),
        })
        last_runtime_log_persist = current_time
    except Exception as exc:
        print(f"[DEPLOY] Failed to persist runtime logs: {exc}")


def set_runtime_log_status(status: str, **fields):
    with runtime_logs_lock:
        runtime_log_state["status"] = status
        for key, value in fields.items():
            runtime_log_state[key] = value
    persist_runtime_logs(force=True)


def append_runtime_log(phase: str, line: str, persist: bool = True):
    raw_line = (line or "").rstrip("\r\n")
    clean_line = strip_ansi(raw_line)
    if not clean_line:
        return

    print(raw_line, flush=True)
    entry = {
        "timestamp": now(),
        "phase": phase,
        "message": clean_line,
        "type": classify_log_line(clean_line),
    }
    with runtime_logs_lock:
        entries = runtime_log_state.setdefault(phase, [])
        entries.append(entry)
        if len(entries) > MAX_RUNTIME_LOG_LINES:
            del entries[: len(entries) - MAX_RUNTIME_LOG_LINES]
    if persist:
        persist_runtime_logs()


def stream_process_output(proc, phase: str, capture_event=None):
    if not proc or not proc.stdout:
        return
    try:
        for line in iter(proc.stdout.readline, ""):
            should_capture = capture_event is None or capture_event.is_set()
            if should_capture:
                append_runtime_log(phase, line, persist=True)
            else:
                print(line.rstrip("\r\n"), flush=True)
    finally:
        try:
            proc.stdout.close()
        except Exception:
            pass


def run_curl_json(method: str, url: str, data=None):
    cmd = [
        "curl", "-s", "-X", method, url,
        "-H", f"Authorization: Bearer {CF_TOKEN}",
        "-H", "Content-Type: application/json",
    ]
    if data is not None:
        cmd += ["--data", json.dumps(data)]
    completed = subprocess.run(cmd, capture_output=True, text=True, check=True)
    stdout = completed.stdout.strip()
    return json.loads(stdout) if stdout else {}


def supa_request(method: str, path: str, data=None):
    url = f"{SUPA_URL}{path}"
    headers = {
        "apikey": SUPA_KEY,
        "Authorization": f"Bearer {SUPA_KEY}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates",
    }
    body = None if data is None else json.dumps(data).encode("utf-8")
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            raw = response.read().decode("utf-8").strip()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Supabase request failed for {method} {path}: HTTP {exc.code} {error_body}") from exc


def normalize_project_type(value: str) -> str:
    normalized = str(value or "").strip().lower()
    if "python" in normalized:
        return "python"
    if "node" in normalized:
        return "node"
    return normalized


def pick_config_value(config: dict, key: str, fallback: str = "") -> str:
    value = (config or {}).get(key)
    if value not in (None, ""):
        return str(value).strip()
    return str(fallback or "").strip()


def normalize_env_vars_for_command(value) -> str:
    if value is None:
        value = ENV_VARS_JSON
    if isinstance(value, str):
        try:
            value = json.loads(value or "[]")
        except json.JSONDecodeError:
            value = []

    normalized = []
    for item in value or []:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key") or "").strip()
        if not key:
            continue
        normalized.append({
            "key": key,
            "value": "" if item.get("value") is None else str(item.get("value")),
        })
    return json.dumps(normalized)


def load_latest_deploy_config() -> dict:
    try:
        rows = supa_request(
            "GET",
            server_filter("id,project_name,runtime,build_command,start_command,port,host_name,repo_url,branch,env_vars,database_type,database_url"),
        ) or []
    except Exception as exc:
        print(f"[DEPLOY] Failed to load latest deploy config; using current command args: {exc}")
        return {}
    return rows[0] if rows else {}


def build_redeploy_command(commit: str) -> str:
    latest_config = load_latest_deploy_config()
    server_id = pick_config_value(latest_config, "id", SERVER_ID)
    project_name = pick_config_value(latest_config, "project_name", PROJECT_NAME)
    project_type = normalize_project_type(pick_config_value(latest_config, "runtime", PROJECT_TYPE)) or PROJECT_TYPE
    build_cmd = pick_config_value(latest_config, "build_command", BUILD_CMD)
    start_cmd = pick_config_value(latest_config, "start_command", START_CMD)
    port = pick_config_value(latest_config, "port", PORT)
    host_name = pick_config_value(latest_config, "host_name", HOST_NAME)
    repo_url = pick_config_value(latest_config, "repo_url", REPO_URL)
    branch = pick_config_value(latest_config, "branch", BRANCH)
    database_type = pick_config_value(latest_config, "database_type", DATABASE_TYPE) or "none"
    database_url = pick_config_value(latest_config, "database_url", MONGODB_URI)
    env_vars_json = normalize_env_vars_for_command(
        latest_config.get("env_vars") if "env_vars" in latest_config else ENV_VARS_JSON
    )

    command = (
        "curl -fsSL https://raw.githubusercontent.com/"
        "nived-padikkal/blank-repo/main/deploy.sh | "
        f"bash -s -- --project-name {json.dumps(project_name)} "
        f"--type {json.dumps(project_type)} "
        f"--build {json.dumps(build_cmd)} "
        f"--start {json.dumps(start_cmd)} "
        f"--port {json.dumps(port)} "
        f"--host-name {json.dumps(host_name)} "
        f"--repo-url {json.dumps(repo_url)}"
    )
    if server_id:
        command += f" --server-id {json.dumps(server_id)}"
    if branch:
        command += f" --branch {json.dumps(branch)}"
    if commit:
        command += f" --commit {json.dumps(commit)}"
    if database_type and database_type != "none":
        command += f" --database-type {json.dumps(database_type)}"
        if database_url:
            command += f" --database-url {json.dumps(database_url)}"
    if env_vars_json and env_vars_json != "[]":
        command += f" --env-vars {json.dumps(env_vars_json)}"
    command += f" --cf-token {json.dumps(CF_TOKEN)}"
    command += f" --zone-id {json.dumps(ZONE_ID)}"
    command += f" --account-id {json.dumps(ACCOUNT_ID)}"
    command += f" --supa-url {json.dumps(SUPA_URL)}"
    command += f" --supa-key {json.dumps(SUPA_KEY)}"
    return command


def queue_auto_restart():
    target_commit = WORKING_COMMIT_ID or REQUESTED_COMMIT
    if not target_commit:
        print("[DEPLOY] Auto-restart skipped because no current commit is available")
        return False

    try:
        supa_request("POST", "/rest/v1/jules_curl", {
            "request_curl": build_redeploy_command(target_commit),
        })
        print(f"[DEPLOY] Auto-restart queued for commit {target_commit}")
        return True
    except Exception as exc:
        print(f"[DEPLOY] Failed to queue auto-restart: {exc}")
        return False


def queue_requested_redeploy():
    if not remote_stop_requested:
        return

    try:
        rows = supa_request(
            "GET",
            server_filter("commit_version,working_commit_id,build_cancel_requested"),
        ) or []
    except Exception as exc:
        print(f"[DEPLOY] Failed to read pending redeploy state: {exc}")
        return

    row = rows[0] if rows else {}
    if bool((row or {}).get("build_cancel_requested")):
        print("[DEPLOY] Build cancel request is active; skipping deferred redeploy queue")
        return

    target_commit = (
        str((row or {}).get("commit_version") or "").strip()
    )
    current_commit = str((row or {}).get("working_commit_id") or WORKING_COMMIT_ID or "").strip()

    if not target_commit:
        print("[DEPLOY] No target commit found for redeploy")
        return

    if target_commit == current_commit:
        print("[DEPLOY] Requested commit matches current working commit; skipping deferred redeploy queue")
        return

    try:
        supa_request("POST", "/rest/v1/jules_curl", {
            "request_curl": build_redeploy_command(target_commit),
        })
        print(f"[DEPLOY] Deferred redeploy queued for commit {target_commit}")
    except Exception as exc:
        print(f"[DEPLOY] Failed to queue deferred redeploy: {exc}")


def server_filter(select_clause: str = "*") -> str:
    if SERVER_ID:
        return f"/rest/v1/servers?id=eq.{urllib.parse.quote(SERVER_ID, safe='')}&select={select_clause}"
    return f"/rest/v1/servers?host_name=eq.{urllib.parse.quote(HOST_NAME, safe='')}&select={select_clause}"


def round_metric(value):
    if value is None:
        return None
    return round(float(value), 2)


def read_cpu_times():
    try:
        with open("/proc/stat", "r", encoding="utf-8") as stat_file:
            first_line = stat_file.readline().strip()
    except OSError:
        return None
    if not first_line.startswith("cpu "):
        return None
    parts = first_line.split()[1:]
    try:
        values = [int(part) for part in parts]
    except ValueError:
        return None
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    total = sum(values)
    return total, idle


previous_cpu_times = read_cpu_times()


def read_memory_usage():
    mem_total_kb = None
    mem_available_kb = None
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as meminfo:
            for line in meminfo:
                if line.startswith("MemTotal:"):
                    mem_total_kb = int(line.split()[1])
                elif line.startswith("MemAvailable:"):
                    mem_available_kb = int(line.split()[1])
                if mem_total_kb is not None and mem_available_kb is not None:
                    break
    except (OSError, ValueError):
        return None, None

    if mem_total_kb is None or mem_available_kb is None:
        return None, None

    used_kb = max(mem_total_kb - mem_available_kb, 0)
    return used_kb / (1024 * 1024), mem_total_kb / (1024 * 1024)


def read_disk_usage():
    try:
        usage = shutil.disk_usage(APP_DIR if os.path.isdir(APP_DIR) else "/")
    except OSError:
        return None, None
    used_gb = (usage.total - usage.free) / (1024 ** 3)
    total_gb = usage.total / (1024 ** 3)
    return used_gb, total_gb


def collect_resource_usage():
    global previous_cpu_times

    cpu_percent = None
    current_cpu_times = read_cpu_times()
    if current_cpu_times and previous_cpu_times:
        total_delta = current_cpu_times[0] - previous_cpu_times[0]
        idle_delta = current_cpu_times[1] - previous_cpu_times[1]
        if total_delta > 0:
            cpu_percent = max(0.0, min(100.0, (1 - (idle_delta / total_delta)) * 100))
    previous_cpu_times = current_cpu_times or previous_cpu_times

    memory_used_gb, memory_total_gb = read_memory_usage()
    disk_used_gb, disk_total_gb = read_disk_usage()

    return {
        "cpu_percent": round_metric(cpu_percent),
        "memory_used_gb": round_metric(memory_used_gb),
        "memory_total_gb": round_metric(memory_total_gb),
        "disk_used_gb": round_metric(disk_used_gb),
        "disk_total_gb": round_metric(disk_total_gb),
    }


def set_server_state(
    status: bool,
    is_stopped: bool,
    start_datetime=None,
    resource_usage=None,
    sync_deployment_ids: bool = True,
    build_cancel_requested=None,
):
    payload = {
        "status": status,
        "is_stopped": is_stopped,
        "last_checked": now(),
        "resource_usage": resource_usage or collect_resource_usage(),
    }
    if sync_deployment_ids:
        payload["commit_version"] = REQUESTED_COMMIT or WORKING_COMMIT_ID
        payload["working_commit_id"] = WORKING_COMMIT_ID
    if ACTIVE_TUNNEL_ID:
        payload["tunnel_id"] = ACTIVE_TUNNEL_ID
    if ACTIVE_TUNNEL_TOKEN:
        payload["tunnel_token"] = ACTIVE_TUNNEL_TOKEN
    if start_datetime:
        payload["start_datetime"] = start_datetime
    if build_cancel_requested is not None:
        payload["build_cancel_requested"] = build_cancel_requested

    existing = supa_request(
        "GET",
        server_filter("id,host_name"),
    )
    if existing:
        supa_request(
            "PATCH",
            server_filter(),
            payload,
        )
    elif SERVER_ID:
        print(f"[DEPLOY] Server row {SERVER_ID} was not visible for initial lookup; skipping fallback insert")
    else:
        payload["host_name"] = HOST_NAME
        supa_request("POST", "/rest/v1/servers", payload)


def update_server_heartbeat(status: bool):
    payload = {
        "status": status,
        "is_stopped": False,
        "build_cancel_requested": False,
        "last_checked": now(),
        "resource_usage": collect_resource_usage(),
        "commit_version": REQUESTED_COMMIT or WORKING_COMMIT_ID,
        "working_commit_id": WORKING_COMMIT_ID,
    }
    if ACTIVE_TUNNEL_ID:
        payload["tunnel_id"] = ACTIVE_TUNNEL_ID
    if ACTIVE_TUNNEL_TOKEN:
        payload["tunnel_token"] = ACTIVE_TUNNEL_TOKEN
    supa_request(
        "PATCH",
        server_filter(),
        payload,
    )


def wait_for_http_ready(url: str, timeout_seconds: int) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5):
                return True
        except Exception:
            time.sleep(1)
    return False


def is_http_alive(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=5):
            return True
    except Exception:
        return False


def is_port_open(port: str) -> bool:
    import socket

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(1)
    try:
        return sock.connect_ex(("127.0.0.1", int(port))) == 0
    finally:
        sock.close()


def mongodb_target():
    uri = (MONGODB_URI or "mongodb://localhost:27017/").strip()
    try:
        parsed = urllib.parse.urlparse(uri)
    except Exception:
        return "127.0.0.1", 27017, uri

    host = parsed.hostname or "localhost"
    try:
        port = parsed.port or 27017
    except ValueError:
        port = 27017
    connect_host = "127.0.0.1" if host in {"localhost", "::1"} else host
    return connect_host, port, uri


def should_prepare_local_mongodb() -> bool:
    uri = (MONGODB_URI or "").strip().lower()
    uses_mongodb = DATABASE_TYPE in {"mongo", "mongodb"} or uri.startswith(("mongodb://", "mongodb+srv://"))
    if not uses_mongodb or uri.startswith("mongodb+srv://"):
        return False

    host, _, _ = mongodb_target()
    return host in {"localhost", "127.0.0.1", "::1"}


def privileged_command(cmd):
    try:
        is_root = os.geteuid() == 0
    except AttributeError:
        is_root = False
    if is_root:
        return cmd
    if shutil.which("sudo"):
        return ["sudo", "-n", *cmd]
    return []


def run_privileged(cmd, *, check=True, input_data=None):
    final_cmd = privileged_command(cmd)
    if not final_cmd:
        raise RuntimeError("MongoDB setup requires root or passwordless sudo")
    return subprocess.run(
        final_cmd,
        input=input_data,
        capture_output=True,
        check=check,
    )


def read_os_release() -> dict:
    values = {}
    try:
        with open("/etc/os-release", "r", encoding="utf-8") as os_release:
            for line in os_release:
                if "=" not in line:
                    continue
                key, value = line.rstrip().split("=", 1)
                values[key] = value.strip().strip('"')
    except OSError:
        pass
    return values


def write_root_file(path: str, content: str):
    try:
        is_root = os.geteuid() == 0
    except AttributeError:
        is_root = False
    if is_root:
        with open(path, "w", encoding="utf-8") as target_file:
            target_file.write(content)
        return
    final_cmd = privileged_command(["tee", path])
    if not final_cmd:
        raise RuntimeError("MongoDB repository setup requires root or passwordless sudo")
    subprocess.run(
        final_cmd,
        input=content.encode("utf-8"),
        stdout=subprocess.DEVNULL,
        check=True,
    )


def add_mongodb_apt_repository() -> bool:
    if not shutil.which("curl") or not shutil.which("gpg"):
        run_privileged(["apt-get", "update"], check=False)
        run_privileged(["apt-get", "install", "-y", "curl", "gnupg", "ca-certificates"], check=False)

    os_release = read_os_release()
    distro_id = (os_release.get("ID") or "").lower()
    codename = os_release.get("VERSION_CODENAME") or os_release.get("UBUNTU_CODENAME") or ""
    mongo_version = "7.0"
    keyring_path = f"/usr/share/keyrings/mongodb-server-{mongo_version}.gpg"

    if distro_id == "ubuntu":
        repo_codename = codename if codename in {"focal", "jammy"} else "jammy"
        repo_line = (
            f"deb [ arch=amd64,arm64 signed-by={keyring_path} ] "
            f"https://repo.mongodb.org/apt/ubuntu {repo_codename}/mongodb-org/{mongo_version} multiverse\n"
        )
    elif distro_id == "debian":
        repo_codename = codename if codename in {"bullseye", "bookworm"} else "bookworm"
        repo_line = (
            f"deb [ arch=amd64,arm64 signed-by={keyring_path} ] "
            f"https://repo.mongodb.org/apt/debian {repo_codename}/mongodb-org/{mongo_version} main\n"
        )
    else:
        return False

    key_response = urllib.request.urlopen(
        f"https://pgp.mongodb.com/server-{mongo_version}.asc",
        timeout=30,
    )
    key_data = key_response.read()
    run_privileged(["gpg", "--batch", "--yes", "--dearmor", "-o", keyring_path], input_data=key_data)
    write_root_file(f"/etc/apt/sources.list.d/mongodb-org-{mongo_version}.list", repo_line)
    return True


def install_mongodb_if_needed():
    if shutil.which("mongod"):
        return
    if not shutil.which("apt-get"):
        raise RuntimeError("MongoDB is not installed and apt-get is unavailable")

    append_runtime_log("build", "[DEPLOY] Installing MongoDB runtime", persist=True)
    run_privileged(["apt-get", "update"], check=False)
    for package_name in ("mongodb-org", "mongodb", "mongodb-server-core"):
        result = run_privileged(["apt-get", "install", "-y", package_name], check=False)
        if result.returncode == 0 and shutil.which("mongod"):
            return

    if add_mongodb_apt_repository():
        run_privileged(["apt-get", "update"], check=False)
        run_privileged(["apt-get", "install", "-y", "mongodb-org"], check=False)

    if not shutil.which("mongod"):
        raise RuntimeError("MongoDB installation failed; mongod was not found")


def start_local_mongodb():
    global mongo_proc
    host, port, uri = mongodb_target()
    if is_port_open(str(port)):
        append_runtime_log("build", f"[DEPLOY] MongoDB already available at {uri}", persist=True)
        return

    append_runtime_log("build", f"[DEPLOY] Starting MongoDB at {uri}", persist=True)
    for service_cmd in (["systemctl", "start", "mongod"], ["service", "mongod", "start"]):
        try:
            run_privileged(service_cmd, check=False)
            if wait_for_port_open(port, 15):
                return
        except Exception:
            pass

    data_dir = f"/tmp/mhserver-mongodb-{port}"
    os.makedirs(data_dir, exist_ok=True)
    log_path = os.path.join(data_dir, "mongod.log")
    log_file = open(log_path, "a", encoding="utf-8")
    mongo_proc = subprocess.Popen(
        [
            "mongod",
            "--dbpath", data_dir,
            "--bind_ip", host,
            "--port", str(port),
        ],
        stdout=log_file,
        stderr=subprocess.STDOUT,
        preexec_fn=os.setsid,
    )
    if not wait_for_port_open(port, 30):
        raise RuntimeError(f"MongoDB did not become ready on port {port}")


def wait_for_port_open(port: int, timeout_seconds: int) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if is_port_open(str(port)):
            return True
        time.sleep(1)
    return is_port_open(str(port))


def prepare_database_services():
    if not should_prepare_local_mongodb():
        return
    install_mongodb_if_needed()
    start_local_mongodb()
    append_runtime_log("build", "[DEPLOY] MongoDB is ready", persist=True)


def build_process_env():
    env = os.environ.copy()
    for item in RUNTIME_ENV_VARS:
        key = str(item.get("key") or "").strip()
        if not key:
            continue
        env[key] = "" if item.get("value") is None else str(item.get("value"))

    if DATABASE_TYPE in {"mongo", "mongodb"} or (MONGODB_URI or "").lower().startswith("mongodb"):
        mongo_uri = MONGODB_URI or "mongodb://localhost:27017/"
        env["MHSERVER_DATABASE_TYPE"] = "mongodb"
        env["MONGODB_URI"] = mongo_uri
        env["MONGO_URI"] = mongo_uri
        env["DATABASE_URL"] = mongo_uri
    return env


def process_alive(proc) -> bool:
    return proc is not None and proc.poll() is None


def is_build_cancel_requested() -> bool:
    try:
        rows = supa_request(
            "GET",
            server_filter("is_stopped,build_cancel_requested"),
        ) or []
    except Exception as exc:
        print(f"[DEPLOY] Failed to poll build cancel flag: {exc}")
        return False
    row = rows[0] if rows else {}
    return bool((row or {}).get("build_cancel_requested")) or bool((row or {}).get("is_stopped"))


def start_build():
    append_runtime_log("build", f"[DEPLOY] Running build: {BUILD_CMD}", persist=True)
    return subprocess.Popen(
        ["bash", "-lc", f"exec {BUILD_CMD}"],
        cwd=APP_DIR,
        env=build_process_env(),
        preexec_fn=os.setsid,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )


def cancel_build(reason: str):
    global shutdown_started, remote_stop_requested, full_system_shutdown_requested
    if shutdown_started:
        return
    shutdown_started = True
    remote_stop_requested = True
    full_system_shutdown_requested = True

    print(f"[STOP] Cancel requested during build/startup: {reason}")
    set_runtime_log_status("cancelled", failed_at=now())
    terminate_group(build_proc, "build", 10)
    terminate_group(app_proc, "application", 15)
    terminate_group(tunnel_proc, "cloudflared", 10)
    terminate_group(mongo_proc, "mongodb", 15)
    try:
        set_server_state(
            status=False,
            is_stopped=True,
            sync_deployment_ids=False,
            build_cancel_requested=False,
        )
    except Exception as exc:
        print(f"[STOP] Failed to persist build cancellation state: {exc}")

    if full_system_shutdown_requested:
        print("[STOP] Requesting full system shutdown")
        shutdown_commands = [
            ["sudo", "-n", "shutdown", "-h", "now"],
            ["/sbin/shutdown", "-h", "now"],
            ["shutdown", "-h", "now"],
            ["systemctl", "poweroff"],
            ["poweroff"],
        ]
        for cmd in shutdown_commands:
            try:
                subprocess.Popen(cmd)
                print(f"[STOP] System shutdown command issued: {' '.join(cmd)}")
                break
            except FileNotFoundError:
                continue
            except Exception as exc:
                print(f"[STOP] Shutdown command failed ({' '.join(cmd)}): {exc}")
        else:
            print("[STOP] No system shutdown command could be executed")

    sys.exit(0)


def terminate_group(proc, name: str, timeout_seconds: int):
    if not process_alive(proc):
        return

    pgid = os.getpgid(proc.pid)
    print(f"[STOP] SIGTERM -> {name} (pgid={pgid})")
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return

    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if proc.poll() is not None:
            print(f"[STOP] {name} exited cleanly")
            return
        time.sleep(0.5)

    print(f"[STOP] SIGKILL -> {name} (pgid={pgid})")
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait(timeout=5)


def wait_for_port_close(port: str, timeout_seconds: int) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if not is_port_open(port):
            return True
        time.sleep(0.5)
    return not is_port_open(port)


shutdown_started = False
remote_stop_requested = False
full_system_shutdown_requested = False
deployment_in_progress = True


def graceful_shutdown(reason: str):
    global shutdown_started
    if shutdown_started:
        return
    shutdown_started = True

    print(f"[STOP] Shutdown requested: {reason}")
    if deployment_in_progress:
        set_runtime_log_status("failed", failed_at=now())
    try:
        set_server_state(
            status=False,
            is_stopped=True,
            sync_deployment_ids=False,
            build_cancel_requested=False,
        )
    except Exception as exc:
        print(f"[STOP] Failed to update server state: {exc}")

    terminate_group(app_proc, "application", 25)
    if not wait_for_port_close(PORT, 10):
        print(f"[STOP] Port {PORT} is still open after app shutdown")
    terminate_group(tunnel_proc, "cloudflared", 15)
    terminate_group(mongo_proc, "mongodb", 15)
    queue_requested_redeploy()
    print("[STOP] Graceful shutdown complete")

    if full_system_shutdown_requested:
        print("[STOP] Requesting full system shutdown")
        shutdown_commands = [
            ["sudo", "-n", "shutdown", "-h", "now"],
            ["/sbin/shutdown", "-h", "now"],
            ["shutdown", "-h", "now"],
            ["systemctl", "poweroff"],
            ["poweroff"],
        ]
        for cmd in shutdown_commands:
            try:
                subprocess.Popen(cmd)
                print(f"[STOP] System shutdown command issued: {' '.join(cmd)}")
                break
            except FileNotFoundError:
                continue
            except Exception as exc:
                print(f"[STOP] Shutdown command failed ({' '.join(cmd)}): {exc}")
        else:
            print("[STOP] No system shutdown command could be executed")

    sys.exit(0)


def handle_signal(signum, _frame):
    graceful_shutdown(f"signal {signum}")


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


def sanitize_tunnel_name(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", value or "").strip("-")
    return cleaned or "deployment"


def load_saved_tunnel() -> tuple[str, str]:
    try:
        rows = supa_request(
            "GET",
            server_filter("tunnel_id,tunnel_token"),
        ) or []
    except Exception as exc:
        print(f"[DEPLOY] Failed to load saved tunnel from server row: {exc}")
        return "", ""

    row = rows[0] if rows else {}
    tunnel_id = str((row or {}).get("tunnel_id") or "").strip()
    tunnel_token = str((row or {}).get("tunnel_token") or "").strip()
    return tunnel_id, tunnel_token


def create_tunnel() -> tuple[str, str]:
    name_seed = SERVER_ID or HOST_NAME or PROJECT_NAME
    tunnel_name = sanitize_tunnel_name(f"{name_seed}-{int(time.time())}")
    response = run_curl_json(
        "POST",
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel",
        {
            "name": tunnel_name,
            "config_src": "cloudflare",
        },
    )
    result = response.get("result") or {}
    tunnel_id = str(result.get("id") or "").strip()
    tunnel_token = str(result.get("token") or "").strip()
    if not tunnel_id or not tunnel_token:
        raise RuntimeError("Cloudflare did not return a tunnel id/token for the new deployment tunnel")
    print(f"[DEPLOY] Created dedicated tunnel: {tunnel_id}")
    return tunnel_id, tunnel_token


def ensure_tunnel() -> tuple[str, str]:
    saved_tunnel_id, saved_tunnel_token = load_saved_tunnel()
    if saved_tunnel_id and saved_tunnel_token:
        print(f"[DEPLOY] Reusing saved tunnel: {saved_tunnel_id}")
        return saved_tunnel_id, saved_tunnel_token

    if TUNNEL_TOKEN:
        print("[DEPLOY] Tunnel token argument was provided but saved tunnel reuse requires DB-backed tunnel_id and tunnel_token")

    return create_tunnel()


def configure_tunnel(tunnel_id: str):
    ingress = {
        "config": {
            "ingress": [
                {"hostname": HOST_NAME, "service": LOCAL_URL},
                {"service": "http_status:404"},
            ]
        }
    }
    print(f"[DEPLOY] Configuring dedicated tunnel for host {HOST_NAME}")
    run_curl_json(
        "PUT",
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel/{tunnel_id}/configurations",
        ingress,
    )

    applied_config_response = run_curl_json(
        "GET",
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel/{tunnel_id}/configurations",
    )
    applied_config = (applied_config_response.get("result") or {}).get("config") or {}
    applied_ingress = applied_config.get("ingress") or []
    applied_hostnames = [
        str(rule.get("hostname") or "").strip()
        for rule in applied_ingress
        if isinstance(rule, dict) and rule.get("hostname")
    ]
    unexpected_hostnames = [hostname for hostname in applied_hostnames if hostname != HOST_NAME]
    if unexpected_hostnames:
        raise RuntimeError(
            "Tunnel config verification failed. Unexpected hostnames remain: "
            + ", ".join(unexpected_hostnames)
        )
    print(f"[DEPLOY] Tunnel config verified for host {HOST_NAME}")

    dns_query = run_curl_json(
        "GET",
        f"https://api.cloudflare.com/client/v4/zones/{ZONE_ID}/dns_records?name={HOST_NAME}&type=CNAME",
    )
    records = dns_query.get("result") or []
    record_id = records[0]["id"] if records else None
    cname_payload = {
        "type": "CNAME",
        "name": HOST_NAME,
        "content": f"{tunnel_id}.cfargotunnel.com",
        "ttl": 1,
        "proxied": True,
    }
    if record_id:
        run_curl_json(
            "PUT",
            f"https://api.cloudflare.com/client/v4/zones/{ZONE_ID}/dns_records/{record_id}",
            cname_payload,
        )
    else:
        run_curl_json(
            "POST",
            f"https://api.cloudflare.com/client/v4/zones/{ZONE_ID}/dns_records",
            cname_payload,
        )
    print("[DEPLOY] Tunnel ingress and DNS configured")


def start_application():
    env = build_process_env()
    env["PORT"] = PORT
    env["HOST"] = "0.0.0.0"
    env["NODE_ENV"] = "production"
    append_runtime_log("start", f"[DEPLOY] Starting {PROJECT_TYPE} app: {START_CMD}", persist=True)
    return subprocess.Popen(
        ["bash", "-lc", f"exec {START_CMD}"],
        cwd=APP_DIR,
        env=env,
        preexec_fn=os.setsid,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )


def start_tunnel(tunnel_token: str):
    print("[DEPLOY] Starting cloudflared tunnel")
    return subprocess.Popen(
        ["/tmp/cloudflared", "tunnel", "run", "--token", tunnel_token],
        cwd=APP_DIR,
        preexec_fn=os.setsid,
    )


start_time = now()
with runtime_logs_lock:
    runtime_log_state["started_at"] = start_time
try:
    set_server_state(
        status=False,
        is_stopped=False,
        start_datetime=start_time,
        build_cancel_requested=False,
    )
except Exception as exc:
    print(f"[DEPLOY] Initial server state update failed: {exc}")
persist_runtime_logs(force=True)

ACTIVE_TUNNEL_ID, ACTIVE_TUNNEL_TOKEN = ensure_tunnel()
configure_tunnel(ACTIVE_TUNNEL_ID)

try:
    prepare_database_services()
except Exception as exc:
    set_runtime_log_status("failed", failed_at=now())
    try:
        set_server_state(
            status=False,
            is_stopped=True,
            sync_deployment_ids=False,
            build_cancel_requested=False,
        )
    except Exception as state_exc:
        print(f"[DEPLOY] Failed to persist database setup failure state: {state_exc}")
    raise RuntimeError(f"Database setup failed: {exc}") from exc

build_proc = start_build()
build_reader = threading.Thread(target=stream_process_output, args=(build_proc, "build"), daemon=True)
build_reader.start()
while process_alive(build_proc):
    time.sleep(5)
    if is_build_cancel_requested():
        cancel_build("remote stop requested during build")

build_exit_code = build_proc.wait()
build_reader.join(timeout=5)
with runtime_logs_lock:
    runtime_log_state["build_exit_code"] = build_exit_code
if build_exit_code != 0:
    set_runtime_log_status("failed", failed_at=now())
    try:
        set_server_state(
            status=False,
            is_stopped=True,
            sync_deployment_ids=False,
            build_cancel_requested=False,
        )
    except Exception as exc:
        print(f"[DEPLOY] Failed to persist build failure state: {exc}")
    raise RuntimeError(f"Build command failed with exit code {build_exit_code}")
persist_runtime_logs(force=True)

app_proc = start_application()
startup_capture_event = threading.Event()
startup_capture_event.set()
app_reader = threading.Thread(target=stream_process_output, args=(app_proc, "start", startup_capture_event), daemon=True)
app_reader.start()
readiness_deadline = time.time() + 60
while time.time() < readiness_deadline:
    if is_build_cancel_requested():
        cancel_build("remote stop requested during startup")
    if is_http_alive(LOCAL_URL):
        break
    time.sleep(5)
else:
    set_runtime_log_status("failed", failed_at=now())
    graceful_shutdown("application failed readiness check")

startup_capture_event.clear()

try:
    set_server_state(
        status=True,
        is_stopped=False,
        start_datetime=start_time,
        build_cancel_requested=False,
    )
except Exception as exc:
    print(f"[DEPLOY] Ready server state update failed: {exc}")
deployment_in_progress = False
append_runtime_log("start", f"[DEPLOY] Application ready on {LOCAL_URL}", persist=True)
set_runtime_log_status("running", ready_at=now())
tunnel_proc = start_tunnel(ACTIVE_TUNNEL_TOKEN)
time.sleep(2)

while True:
    time.sleep(30)

    if not process_alive(app_proc):
        graceful_shutdown("application exited")
    if not process_alive(tunnel_proc):
        graceful_shutdown("cloudflared exited")

    if not auto_restart_queued and (time.time() - boot_epoch) >= AUTO_RESTART_AFTER_SECONDS:
        auto_restart_queued = queue_auto_restart()

    try:
        stop_rows = supa_request(
            "GET",
            server_filter("is_stopped"),
        )
        if stop_rows and stop_rows[0].get("is_stopped"):
            if deployment_in_progress:
                print("[MONITOR] Ignoring remote stop while deployment/build is in progress")
                continue
            full_system_shutdown_requested = True
            remote_stop_requested = True
            graceful_shutdown("remote stop requested")
    except urllib.error.URLError as exc:
        print(f"[MONITOR] Supabase poll failed: {exc}")

    if shutdown_started or remote_stop_requested:
        continue

    alive = is_http_alive(LOCAL_URL)
    try:
        update_server_heartbeat(alive)
    except Exception as exc:
        print(f"[HEARTBEAT] Failed to update status: {exc}")
PY
