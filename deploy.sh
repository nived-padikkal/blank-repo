#!/bin/bash
# ============================================================
# deploy.sh - Universal project deployer via Cloudflare Tunnel
# ============================================================

set -euo pipefail

PROJECT_NAME=""
PROJECT_TYPE=""
BUILD_CMD=""
START_CMD=""
PORT=""
HOST_NAME=""
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
WEBHOOK_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name) PROJECT_NAME="$2"; shift 2 ;;
    --type)         PROJECT_TYPE="$2"; shift 2 ;;
    --build)        BUILD_CMD="$2"; shift 2 ;;
    --start)        START_CMD="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --host-name)    HOST_NAME="$2"; shift 2 ;;
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
    --webhook-url)  WEBHOOK_URL="$2"; shift 2 ;;
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
[[ -z "$TUNNEL_TOKEN" ]] && MISSING="$MISSING --tunnel-token"
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
echo "  type      : $PROJECT_TYPE"
echo "  build     : $BUILD_CMD"
echo "  start     : $START_CMD"
echo "  port      : $PORT"
echo "  host      : $HOST_NAME"
echo "  repo      : $REPO_URL"
[[ -n "$BRANCH" ]] && echo "  branch    : $BRANCH"
[[ -n "$COMMIT" ]] && echo "  commit    : $COMMIT"
[[ "$ENV_VARS_JSON" != "[]" && -n "$ENV_VARS_JSON" ]] && echo "  env vars  : configured"
echo "=========================================="
echo ""

APP_DIR="/tmp/$PROJECT_NAME"

remote_stop_requested() {
  SUPA_URL="$SUPA_URL" SUPA_KEY="$SUPA_KEY" HOST_NAME="$HOST_NAME" python3 - <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request

supa_url = (os.environ.get("SUPA_URL") or "").strip()
supa_key = (os.environ.get("SUPA_KEY") or "").strip()
host_name = (os.environ.get("HOST_NAME") or "").strip()

if not supa_url or not supa_key or not host_name:
    print("0")
    sys.exit(0)

url = (
    f"{supa_url}/rest/v1/servers"
    f"?host_name=eq.{urllib.parse.quote(host_name, safe='')}"
    "&select=is_stopped"
)
request = urllib.request.Request(
    url,
    headers={
        "apikey": supa_key,
        "Authorization": f"Bearer {supa_key}",
        "Accept": "application/json",
    },
)

try:
    with urllib.request.urlopen(request, timeout=5) as response:
        rows = json.loads(response.read().decode("utf-8") or "[]")
except Exception:
    print("0")
    sys.exit(0)

print("1" if rows and rows[0].get("is_stopped") else "0")
PY
}

abort_if_remote_stop_requested() {
  local phase="${1:-deployment}"
  if [[ "$(remote_stop_requested)" == "1" ]]; then
    echo "[STOP] Remote stop requested during $phase"
    exit 0
  fi
}

run_build_with_stop_monitor() {
  echo "[DEPLOY] Running build ..."
  setsid bash -lc "exec $BUILD_CMD" &
  local build_pid=$!
  local build_status=0

  while kill -0 "$build_pid" 2>/dev/null; do
    if [[ "$(remote_stop_requested)" == "1" ]]; then
      echo "[STOP] Remote stop requested while build is running"
      kill -TERM -- "-$build_pid" 2>/dev/null || kill -TERM "$build_pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$build_pid" 2>/dev/null; then
        kill -KILL -- "-$build_pid" 2>/dev/null || kill -KILL "$build_pid" 2>/dev/null || true
      fi
      wait "$build_pid" || true
      exit 0
    fi
    sleep 3
  done

  wait "$build_pid" || build_status=$?
  if [[ "$build_status" -ne 0 ]]; then
    return "$build_status"
  fi
}

abort_if_remote_stop_requested "deployment setup"

echo "[DEPLOY] Cloning $REPO_URL into $APP_DIR ..."
rm -rf "$APP_DIR"
if [[ -n "$BRANCH" ]]; then
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$APP_DIR"
else
  git clone "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR"

abort_if_remote_stop_requested "repository clone"

if [[ -n "$COMMIT" ]]; then
  echo "[DEPLOY] Checking out commit $COMMIT ..."
  git fetch --depth 1 origin "$COMMIT" || git fetch origin "$COMMIT"
  git checkout --detach "$COMMIT"
fi

abort_if_remote_stop_requested "git checkout"

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

abort_if_remote_stop_requested "build preparation"
run_build_with_stop_monitor
abort_if_remote_stop_requested "build completion"

echo "[DEPLOY] Downloading cloudflared ..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /tmp/cloudflared
chmod +x /tmp/cloudflared

export PROJECT_NAME PROJECT_TYPE BUILD_CMD START_CMD PORT HOST_NAME REPO_URL BRANCH APP_DIR ENV_VARS_JSON COMMIT WORKING_COMMIT_ID
export CF_TOKEN ZONE_ID ACCOUNT_ID TUNNEL_TOKEN SUPA_URL SUPA_KEY WEBHOOK_URL

python3 - <<'PY'
import base64
import json
import os
import signal
import shutil
import subprocess
import sys
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
REPO_URL = os.environ["REPO_URL"]
BRANCH = (os.environ.get("BRANCH") or "").strip()
APP_DIR = os.environ["APP_DIR"]
ENV_VARS_JSON = os.environ.get("ENV_VARS_JSON") or "[]"
REQUESTED_COMMIT = (os.environ.get("COMMIT") or "").strip()
WORKING_COMMIT_ID = (os.environ.get("WORKING_COMMIT_ID") or "").strip()

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
TUNNEL_TOKEN = require_env("TUNNEL_TOKEN")
SUPA_URL = require_env("SUPA_URL")
SUPA_KEY = require_env("SUPA_KEY")
WEBHOOK_URL = get_env("WEBHOOK_URL")
LOCAL_URL = f"http://127.0.0.1:{PORT}"

app_proc = None
tunnel_proc = None
webhook_sent = False
boot_epoch = time.time()


def now():
    return datetime.now(timezone.utc).isoformat()


def decode_tunnel_id(token: str) -> str:
    padded = token + "=" * (-len(token) % 4)
    decoded = json.loads(base64.b64decode(padded))
    return decoded["t"]


TUNNEL_ID = decode_tunnel_id(TUNNEL_TOKEN)


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
    with urllib.request.urlopen(request, timeout=15) as response:
        raw = response.read().decode("utf-8").strip()
        return json.loads(raw) if raw else None


def build_redeploy_command(commit: str) -> str:
    command = (
        "curl -fsSL https://raw.githubusercontent.com/"
        "nived-padikkal/blank-repo/main/deploy.sh | "
        f"bash -s -- --project-name {json.dumps(PROJECT_NAME)} "
        f"--type {json.dumps(PROJECT_TYPE)} "
        f"--build {json.dumps(BUILD_CMD)} "
        f"--start {json.dumps(START_CMD)} "
        f"--port {json.dumps(PORT)} "
        f"--host-name {json.dumps(HOST_NAME)} "
        f"--repo-url {json.dumps(REPO_URL)}"
    )
    if BRANCH:
        command += f" --branch {json.dumps(BRANCH)}"
    if commit:
        command += f" --commit {json.dumps(commit)}"
    if ENV_VARS_JSON and ENV_VARS_JSON != "[]":
        command += f" --env-vars {json.dumps(ENV_VARS_JSON)}"
    command += f" --cf-token {json.dumps(CF_TOKEN)}"
    command += f" --zone-id {json.dumps(ZONE_ID)}"
    command += f" --account-id {json.dumps(ACCOUNT_ID)}"
    command += f" --tunnel-token {json.dumps(TUNNEL_TOKEN)}"
    command += f" --supa-url {json.dumps(SUPA_URL)}"
    command += f" --supa-key {json.dumps(SUPA_KEY)}"
    if WEBHOOK_URL:
        command += f" --webhook-url {json.dumps(WEBHOOK_URL)}"
    return command


def queue_requested_redeploy():
    if not remote_stop_requested:
        return

    try:
        rows = supa_request(
            "GET",
            f"/rest/v1/servers?host_name=eq.{urllib.parse.quote(HOST_NAME, safe='')}"
            "&select=commit_version,current_deployment_id,working_commit_id",
        ) or []
    except Exception as exc:
        print(f"[DEPLOY] Failed to read pending redeploy state: {exc}")
        return

    row = rows[0] if rows else {}
    target_commit = (
        str((row or {}).get("current_deployment_id") or "").strip()
        or str((row or {}).get("commit_version") or "").strip()
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
        payload["current_deployment_id"] = WORKING_COMMIT_ID or REQUESTED_COMMIT
    if start_datetime:
        payload["start_datetime"] = start_datetime

    existing = supa_request(
        "GET",
        f"/rest/v1/servers?host_name=eq.{urllib.parse.quote(HOST_NAME, safe='')}&select=host_name",
    )
    if existing:
        supa_request(
            "PATCH",
            f"/rest/v1/servers?host_name=eq.{urllib.parse.quote(HOST_NAME, safe='')}",
            payload,
        )
    else:
        payload["host_name"] = HOST_NAME
        supa_request("POST", "/rest/v1/servers", payload)


def update_server_heartbeat(status: bool):
    supa_request(
        "PATCH",
        f"/rest/v1/servers?host_name=eq.{urllib.parse.quote(HOST_NAME, safe='')}",
        {
            "status": status,
            "is_stopped": False,
            "last_checked": now(),
            "resource_usage": collect_resource_usage(),
            "commit_version": REQUESTED_COMMIT or WORKING_COMMIT_ID,
            "working_commit_id": WORKING_COMMIT_ID,
            "current_deployment_id": WORKING_COMMIT_ID or REQUESTED_COMMIT,
        },
    )


def send_webhook(start_time: str):
    if not WEBHOOK_URL:
        return
    payload = json.dumps({
        "host": HOST_NAME,
        "status": "running",
        "start_datetime": start_time,
        "webhook_fired_at": now(),
        "message": "Server has been running for 5 minutes",
    }).encode("utf-8")
    request = urllib.request.Request(
        WEBHOOK_URL,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=10):
            print("[WEBHOOK] Sent")
    except Exception as exc:
        print(f"[WEBHOOK] Failed: {exc}")


def wait_for_http_ready(url: str, timeout_seconds: int) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if remote_stop_is_requested():
            graceful_shutdown("remote stop requested during startup")
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


def remote_stop_is_requested() -> bool:
    try:
        stop_rows = supa_request(
            "GET",
            f"/rest/v1/servers?host_name=eq.{urllib.parse.quote(HOST_NAME, safe='')}&select=is_stopped",
        )
    except Exception as exc:
        print(f"[MONITOR] Supabase poll failed: {exc}")
        return False
    return bool(stop_rows and stop_rows[0].get("is_stopped"))


def is_port_open(port: str) -> bool:
    import socket

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(1)
    try:
        return sock.connect_ex(("127.0.0.1", int(port))) == 0
    finally:
        sock.close()


def process_alive(proc) -> bool:
    return proc is not None and proc.poll() is None


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
    try:
        set_server_state(status=False, is_stopped=True, sync_deployment_ids=False)
    except Exception as exc:
        print(f"[STOP] Failed to update server state: {exc}")

    terminate_group(app_proc, "application", 25)
    if not wait_for_port_close(PORT, 10):
        print(f"[STOP] Port {PORT} is still open after app shutdown")
    terminate_group(tunnel_proc, "cloudflared", 15)
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


def configure_tunnel():
    current_config_response = run_curl_json(
        "GET",
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel/{TUNNEL_ID}/configurations",
    )
    current_config = (current_config_response.get("result") or {}).get("config") or {}
    current_ingress = current_config.get("ingress") or []

    filtered_ingress = []
    fallback_rule = {"service": "http_status:404"}
    for rule in current_ingress:
        if not isinstance(rule, dict):
            continue
        if rule.get("hostname") == HOST_NAME:
            continue
        if "hostname" not in rule:
            fallback_rule = rule
            continue
        filtered_ingress.append(rule)

    ingress = {
        "config": {
            "ingress": filtered_ingress + [
                {"hostname": HOST_NAME, "service": LOCAL_URL},
                fallback_rule,
            ]
        }
    }
    print(f"[DEPLOY] Configuring tunnel for host {HOST_NAME}")
    run_curl_json(
        "PUT",
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel/{TUNNEL_ID}/configurations",
        ingress,
    )

    dns_query = run_curl_json(
        "GET",
        f"https://api.cloudflare.com/client/v4/zones/{ZONE_ID}/dns_records?name={HOST_NAME}&type=CNAME",
    )
    records = dns_query.get("result") or []
    record_id = records[0]["id"] if records else None
    cname_payload = {
        "type": "CNAME",
        "name": HOST_NAME,
        "content": f"{TUNNEL_ID}.cfargotunnel.com",
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
    env = os.environ.copy()
    try:
        env_vars = json.loads(ENV_VARS_JSON)
    except json.JSONDecodeError:
        env_vars = []
    for item in env_vars:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key") or "").strip()
        if not key:
            continue
        env[key] = "" if item.get("value") is None else str(item.get("value"))
    env["PORT"] = PORT
    env["HOST"] = "0.0.0.0"
    env["NODE_ENV"] = "production"
    print(f"[DEPLOY] Starting {PROJECT_TYPE} app: {START_CMD}")
    return subprocess.Popen(
        ["bash", "-lc", f"exec {START_CMD}"],
        cwd=APP_DIR,
        env=env,
        preexec_fn=os.setsid,
    )


def start_tunnel():
    print("[DEPLOY] Starting cloudflared tunnel")
    return subprocess.Popen(
        ["/tmp/cloudflared", "tunnel", "run", "--token", TUNNEL_TOKEN],
        cwd=APP_DIR,
        preexec_fn=os.setsid,
    )


start_time = now()
set_server_state(status=False, is_stopped=False, start_datetime=start_time)

if remote_stop_is_requested():
    graceful_shutdown("remote stop requested before tunnel configuration")

configure_tunnel()

if remote_stop_is_requested():
    graceful_shutdown("remote stop requested before application start")

app_proc = start_application()
if not wait_for_http_ready(LOCAL_URL, 60):
    graceful_shutdown("application failed readiness check")

set_server_state(status=True, is_stopped=False, start_datetime=start_time)
deployment_in_progress = False
print(f"[DEPLOY] Application ready on {LOCAL_URL}")
tunnel_proc = start_tunnel()
time.sleep(2)

while True:
    time.sleep(30)

    if not webhook_sent and (time.time() - boot_epoch) >= 300:
        send_webhook(start_time)
        webhook_sent = True

    if not process_alive(app_proc):
        graceful_shutdown("application exited")
    if not process_alive(tunnel_proc):
        graceful_shutdown("cloudflared exited")

    try:
        if remote_stop_is_requested():
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
