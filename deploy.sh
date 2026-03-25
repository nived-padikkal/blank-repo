#!/bin/bash
# ============================================================
# deploy.sh - Universal project deployer via Cloudflare Tunnel
#
# Usage:
#   ./deploy.sh \
#     --project-name flask-test \
#     --type python \
#     --build "pip install -r requirements.txt" \
#     --start "python app.py" \
#     --port 5000 \
#     --host-name app.mhserver.dpdns.org \
#     --repo-url https://github.com/nived-padikkal/flask-test
# ============================================================

set -e

# ── 1. Parse named parameters ────────────────────────────────
PROJECT_NAME=""
PROJECT_TYPE=""
BUILD_CMD=""
START_CMD=""
PORT=""
HOST_NAME=""
REPO_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name) PROJECT_NAME="$2"; shift 2 ;;
    --type)         PROJECT_TYPE="$2"; shift 2 ;;
    --build)        BUILD_CMD="$2";    shift 2 ;;
    --start)        START_CMD="$2";    shift 2 ;;
    --port)         PORT="$2";         shift 2 ;;
    --host-name)    HOST_NAME="$2";    shift 2 ;;
    --repo-url)     REPO_URL="$2";     shift 2 ;;
    *)
      echo "[ERROR] Unknown parameter: $1"
      echo ""
      echo "Usage: $0 \\"
      echo "  --project-name <name> \\"
      echo "  --type <python|node|static> \\"
      echo "  --build <build command> \\"
      echo "  --start <start command> \\"
      echo "  --port <port> \\"
      echo "  --host-name <hostname> \\"
      echo "  --repo-url <git repo url>"
      exit 1
      ;;
  esac
done

# ── 2. Validate required fields ──────────────────────────────
MISSING=""
[ -z "$PROJECT_NAME" ] && MISSING="$MISSING --project-name"
[ -z "$PROJECT_TYPE" ] && MISSING="$MISSING --type"
[ -z "$BUILD_CMD"    ] && MISSING="$MISSING --build"
[ -z "$START_CMD"    ] && MISSING="$MISSING --start"
[ -z "$PORT"         ] && MISSING="$MISSING --port"
[ -z "$HOST_NAME"    ] && MISSING="$MISSING --host-name"
[ -z "$REPO_URL"     ] && MISSING="$MISSING --repo-url"

if [ -n "$MISSING" ]; then
  echo "[ERROR] Missing required parameters:$MISSING"
  exit 1
fi

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
echo "=========================================="
echo ""

APP_DIR="/tmp/$PROJECT_NAME"

# ── 3. Clone repo ────────────────────────────────────────────
echo "[DEPLOY] Cloning $REPO_URL into $APP_DIR ..."
rm -rf "$APP_DIR"
git clone "$REPO_URL" "$APP_DIR"
cd "$APP_DIR"

# ── 4. Type-specific build ───────────────────────────────────
echo "[DEPLOY] Running build for type: $PROJECT_TYPE ..."
case "$PROJECT_TYPE" in
  python)
    echo "[BUILD] $BUILD_CMD"
    eval "$BUILD_CMD"
    ;;
  node)
    echo "[BUILD] $BUILD_CMD"
    eval "$BUILD_CMD"
    ;;
  static)
    echo "[BUILD] Static site - skipping build step"
    ;;
  *)
    echo "[BUILD] Unknown type '$PROJECT_TYPE' - running build anyway"
    eval "$BUILD_CMD"
    ;;
esac

# ── 5. Download cloudflared ───────────────────────────────────
echo "[DEPLOY] Downloading cloudflared ..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /tmp/cloudflared
chmod +x /tmp/cloudflared

# ── 6. Persist config for monitor ────────────────────────────
echo "$HOST_NAME" > /tmp/cf_host.txt
echo "$PORT"      > /tmp/cf_port.txt
echo "$APP_DIR"   > /tmp/cf_appdir.txt
echo "$START_CMD" > /tmp/cf_start.txt

# ── 7. Launch via Python (tunnel + monitor) ───────────────────
python3 -c "
import json,base64,subprocess,time,os,signal
from datetime import datetime,timezone

t='eyJhIjoiNWU4Zjg3YjBjZjg1MjEyMDE0MDE4NGEzNmFjZGEyMDgiLCJ0IjoiZmFjOTExNTgtMmUxNC00MGNmLWE5YmMtZTQyNTZkMDJhMzY2IiwicyI6IlpqSXdabVZtWVRZdE1qTTNNeTAwWTJJMExXSmxZell0TURSall6RmxOV1ZtTW1VMSJ9'
t+='='*(-len(t)%4)
d=json.loads(base64.b64decode(t))
tid=d['t']

host      = open('/tmp/cf_host.txt').read().strip()
port      = open('/tmp/cf_port.txt').read().strip()
app_dir   = open('/tmp/cf_appdir.txt').read().strip()
start_cmd = open('/tmp/cf_start.txt').read().strip()

cf_token     = 'cfut_qs9wqP1JvcMUCpNvPGk8vCN9H5Hva95SgZcb5FAp3766f6d6'
zone         = 'd94e02b712e26c4efccb5ff046942078'
account      = '5e8f87b0cf852120140184a36acda208'
tunnel_token = 'eyJhIjoiNWU4Zjg3YjBjZjg1MjEyMDE0MDE4NGEzNmFjZGEyMDgiLCJ0IjoiZmFjOTExNTgtMmUxNC00MGNmLWE5YmMtZTQyNTZkMDJhMzY2IiwicyI6IlpqSXdabVZtWVRZdE1qTTNNeTAwWTJJMExXSmxZell0TURSall6RmxOV1ZtTW1VMSJ9'
SUPA_URL     = 'https://qjisublltugsblgbcxhv.supabase.co'
SUPA_KEY     = 'sb_publishable_QQ8v_ORhTSTUMbYv7zc9cw_vy1eHTzq'
local_url    = f'http://127.0.0.1:{port}'

open('/tmp/cf_ids.txt','w').write(tid)

# ── Configure tunnel ingress ──────────────────────────────────
ingress_data=json.dumps({'config':{'ingress':[{'hostname':host,'service':local_url},{'service':'http_status:404'}]}})
subprocess.run(['curl','-s','-X','PUT',
  f'https://api.cloudflare.com/client/v4/accounts/{account}/cfd_tunnel/{tid}/configurations',
  '-H',f'Authorization: Bearer {cf_token}','-H','Content-Type: application/json',
  '--data',ingress_data])

# ── Upsert DNS CNAME ──────────────────────────────────────────
rec_resp=subprocess.check_output(['curl','-s',
  f'https://api.cloudflare.com/client/v4/zones/{zone}/dns_records?name={host}&type=CNAME',
  '-H',f'Authorization: Bearer {cf_token}']).decode()
rec_raw=json.loads(rec_resp).get('result',[])
rec_id=rec_raw[0]['id'] if rec_raw else ''
cname_data=json.dumps({'type':'CNAME','name':host,'content':tid+'.cfargotunnel.com','ttl':1,'proxied':True})
if rec_id:
    subprocess.run(['curl','-s','-X','PUT',
      f'https://api.cloudflare.com/client/v4/zones/{zone}/dns_records/{rec_id}',
      '-H',f'Authorization: Bearer {cf_token}','-H','Content-Type: application/json',
      '--data',cname_data])
else:
    subprocess.run(['curl','-s','-X','POST',
      f'https://api.cloudflare.com/client/v4/zones/{zone}/dns_records',
      '-H',f'Authorization: Bearer {cf_token}','-H','Content-Type: application/json',
      '--data',cname_data])
print('[DEPLOY] DNS configured')

# ── Write monitor.py ──────────────────────────────────────────
monitor_code=[
'import subprocess,json,os,signal,time',
'from datetime import datetime,timezone',
'HOST       = open(\"/tmp/cf_host.txt\").read().strip()',
'PORT       = open(\"/tmp/cf_port.txt\").read().strip()',
'APP_DIR    = open(\"/tmp/cf_appdir.txt\").read().strip()',
'START_CMD  = open(\"/tmp/cf_start.txt\").read().strip()',
'LOCAL_URL  = f\"http://127.0.0.1:{PORT}\"',
'SUPA_URL   = \"https://qjisublltugsblgbcxhv.supabase.co\"',
'SUPA_KEY   = \"sb_publishable_QQ8v_ORhTSTUMbYv7zc9cw_vy1eHTzq\"',
'WEBHOOK_URL= \"https://webhook.site/a6061d53-ff8f-47da-9eb7-0b6ca13c5f8e\"',
'webhook_sent = False',
'def now(): return datetime.now(timezone.utc).isoformat()',
'def supa(method,path,data=None):',
' cmd=[\"curl\",\"-s\",\"-X\",method,SUPA_URL+path,\"-H\",\"apikey: \"+SUPA_KEY,\"-H\",\"Authorization: Bearer \"+SUPA_KEY,\"-H\",\"Content-Type: application/json\",\"-H\",\"Prefer: resolution=merge-duplicates\"]',
' if data: cmd+=[\"--data\",json.dumps(data)]',
' try:',
'  r=subprocess.check_output(cmd,stderr=subprocess.DEVNULL,timeout=10).decode().strip()',
'  print(\"SUPA RESP:\",r[:100])',
'  return json.loads(r) if r else None',
' except Exception as e: print(\"SUPA ERROR:\",e); return None',
'def register_server(start_time):',
' # Check if host_name row already exists',
' existing=supa(\"GET\",\"/rest/v1/servers?host_name=eq.\"+HOST+\"&select=host_name\")',
' if existing and len(existing)>0:',
'  # Row exists - PATCH to reset state and update start_datetime',
'  supa(\"PATCH\",\"/rest/v1/servers?host_name=eq.\"+HOST,{\"status\":True,\"is_stopped\":False,\"last_checked\":now(),\"start_datetime\":start_time})',
'  print(\"[INIT] Existing host updated - status=True, is_stopped=False, start_datetime:\",start_time)',
' else:',
'  # New row - INSERT',
'  supa(\"POST\",\"/rest/v1/servers\",{\"host_name\":HOST,\"status\":True,\"is_stopped\":False,\"last_checked\":now(),\"start_datetime\":start_time})',
'  print(\"[INIT] New host registered - start_datetime:\",start_time)',
'def send_webhook(start_time):',
' payload=json.dumps({\"host\":HOST,\"status\":\"running\",\"start_datetime\":start_time,\"webhook_fired_at\":now(),\"message\":\"Server has been running for 5 minutes\"})',
' cmd=[\"curl\",\"-s\",\"-X\",\"POST\",WEBHOOK_URL,\"-H\",\"Content-Type: application/json\",\"--data\",payload]',
' try:',
'  r=subprocess.check_output(cmd,stderr=subprocess.DEVNULL,timeout=10).decode().strip()',
'  print(\"[WEBHOOK] Fired successfully:\",r[:100])',
' except Exception as e: print(\"[WEBHOOK] Error:\",e)',
'def kill_all():',
' print(\"[STOP] Sending SIGTERM to all processes...\")',
' for pat in [START_CMD,\"cloudflared tunnel run\"]:',
'  r=subprocess.run([\"pgrep\",\"-f\",pat],capture_output=True,text=True)',
'  for p in r.stdout.strip().split():',
'   try:',
'    pid=int(p)',
'    if pid!=os.getpid():',
'     os.kill(pid,signal.SIGTERM)',
'     print(\"[STOP] SIGTERM sent to PID:\",pid)',
'   except: pass',
' print(\"[STOP] Waiting 3s for graceful exit...\")',
' time.sleep(3)',
' for pat in [START_CMD,\"cloudflared tunnel run\"]:',
'  r=subprocess.run([\"pgrep\",\"-f\",pat],capture_output=True,text=True)',
'  for p in r.stdout.strip().split():',
'   try:',
'    os.kill(int(p),signal.SIGKILL)',
'    print(\"[STOP] SIGKILL sent to PID:\",p)',
'   except: pass',
' print(\"[STOP] All processes terminated. Exiting monitor.\")',
' os._exit(0)',
'# ── One-time startup registration ────────────────────────────',
'start_time = now()',
'boot_epoch = time.time()',
'register_server(start_time)',
'while True:',
' time.sleep(60)',
' if not webhook_sent and (time.time()-boot_epoch)>=300:',
'  send_webhook(start_time)',
'  webhook_sent=True',
' res=supa(\"GET\",\"/rest/v1/servers?host_name=eq.\"+HOST+\"&select=is_stopped\")',
' print(\"[MONITOR] Check:\",res)',
' if res and len(res)>0 and res[0].get(\"is_stopped\"):',
'  print(\"[MONITOR] Stop signal received - initiating shutdown\")',
'  supa(\"PATCH\",\"/rest/v1/servers?host_name=eq.\"+HOST,{\"status\":False,\"is_stopped\":True,\"last_checked\":now()})',
'  kill_all()',
' else:',
'  try:',
'   import urllib.request',
'   urllib.request.urlopen(LOCAL_URL,timeout=5); alive=True',
'  except: alive=False',
'  supa(\"PATCH\",\"/rest/v1/servers?host_name=eq.\"+HOST,{\"status\":alive,\"last_checked\":now()})',
'  print(\"[HEARTBEAT] App alive:\",alive)',
]

open('/tmp/monitor.py','w').write('\n'.join(monitor_code))
print('[DEPLOY] monitor.py written')

# ── Start the app ─────────────────────────────────────────────
print(f'[DEPLOY] Starting: {start_cmd}  in  {app_dir}')
subprocess.Popen(start_cmd.split(), cwd=app_dir)
time.sleep(5)
for _ in range(30):
    try:
        import urllib.request
        urllib.request.urlopen(local_url, timeout=2)
        print(f'[DEPLOY] App ready on {local_url}')
        break
    except:
        time.sleep(1)

# ── Start cloudflared ─────────────────────────────────────────
subprocess.Popen(['/tmp/cloudflared','tunnel','run','--token',tunnel_token])
time.sleep(3)
print('[DEPLOY] Tunnel started - handing off to monitor')
os.execv('/usr/bin/python3',['/usr/bin/python3','/tmp/monitor.py'])
"
