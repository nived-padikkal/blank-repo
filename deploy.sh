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

echo "[DEPLOY] Running build ..."
eval "$BUILD_CMD"

echo "[DEPLOY] Downloading cloudflared ..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /tmp/cloudflared
chmod +x /tmp/cloudflared

export PROJECT_NAME PROJECT_TYPE BUILD_CMD START_CMD PORT HOST_NAME REPO_URL APP_DIR ENV_VARS_JSON

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
START_CMD = os.environ["START_CMD"]
PORT = str(os.environ["PORT"])
HOST_NAME = os.environ["HOST_NAME"]
APP_DIR = os.environ["APP_DIR"]
ENV_VARS_JSON = os.environ.get("ENV_VARS_JSON") or "[]"

CF_TOKEN = "cfut_qs9wqP1JvcMUCpNvPGk8vCN9H5Hva95SgZcb5FAp3766f6d6"
ZONE_ID = "d94e02b712e26c4efccb5ff046942078"
ACCOUNT_ID = "5e8f87b0cf852120140184a36acda208"
TUNNEL_TOKEN = "eyJhIjoiNWU4Zjg3YjBjZjg1MjEyMDE0MDE4NGEzNmFjZGEyMDgiLCJ0IjoiZmFjOTExNTgtMmUxNC00MGNmLWE5YmMtZTQyNTZkMDJhMzY2IiwicyI6IlpqSXdabVZtWVRZdE1qTTNNeTAwWTJJMExXSmxZell0TURSall6RmxOV1ZtTW1VMSJ9"
SUPA_URL = "https://qjisublltugsblgbcxhv.supabase.co"
SUPA_KEY = "sb_publishable_QQ8v_ORhTSTUMbYv7zc9cw_vy1eHTzq"
WEBHOOK_URL = "https://webhook.site/a6061d53-ff8f-47da-9eb7-0b6ca13c5f8e"
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


def set_server_state(status: bool, is_stopped: bool, start_datetime=None, resource_usage=None):
    payload = {
        "status": status,
        "is_stopped": is_stopped,
        "last_checked": now(),
        "resource_usage": resource_usage or collect_resource_usage(),
    }
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
            "last_checked": now(),
            "resource_usage": collect_resource_usage(),
        },
    )


def send_webhook(start_time: str):
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


def graceful_shutdown(reason: str):
    global shutdown_started
    if shutdown_started:
        return
    shutdown_started = True

    print(f"[STOP] Shutdown requested: {reason}")
    try:
        set_server_state(status=False, is_stopped=True)
    except Exception as exc:
        print(f"[STOP] Failed to update server state: {exc}")

    terminate_group(app_proc, "application", 25)
    if not wait_for_port_close(PORT, 10):
        print(f"[STOP] Port {PORT} is still open after app shutdown")
    terminate_group(tunnel_proc, "cloudflared", 15)
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
    ingress = {
        "config": {
            "ingress": [
                {"hostname": HOST_NAME, "service": LOCAL_URL},
                {"service": "http_status:404"},
            ]
        }
    }
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

configure_tunnel()

app_proc = start_application()
if not wait_for_http_ready(LOCAL_URL, 60):
    graceful_shutdown("application failed readiness check")

set_server_state(status=True, is_stopped=False, start_datetime=start_time)
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
        stop_rows = supa_request(
            "GET",
            f"/rest/v1/servers?host_name=eq.{urllib.parse.quote(HOST_NAME, safe='')}&select=is_stopped",
        )
        if stop_rows and stop_rows[0].get("is_stopped"):
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
