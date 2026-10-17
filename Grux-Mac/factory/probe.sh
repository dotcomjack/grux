#!/bin/bash
# One Daytona sandbox: create, exec, delete. The key stays in the environment.
# PROBE_SNAPSHOT defaults to daytona-small. Set it to windows-small for the smoke.
set -euo pipefail
umask 077

if [[ -z "${DAYTONA_API_KEY:-}" ]]; then
  echo "key missing"
  exit 2
fi

case "${PROBE_SNAPSHOT:-daytona-small}" in
  *[!A-Za-z0-9._:-]*) echo "bad snapshot name"; exit 2 ;;
esac

SNAP="${PROBE_SNAPSHOT:-daytona-small}"
CMD="${PROBE_COMMAND:-echo factory-probe}"
TIMEOUT="${PROBE_TIMEOUT:-30}"
CREATE_URL="https://app.daytona.io/api/sandbox"
EXEC_TEMPLATE="https://proxy.app.daytona.io/toolbox/{id}/process/execute"
DELETE_TEMPLATE="https://app.daytona.io/api/sandbox/{id}"
LIST_URL="https://app.daytona.io/api/sandbox"
AUTH_HEADER="Authorization"

WORKDIR="$(mktemp -d /tmp/grux-factory-probe.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

python3 - "$WORKDIR/create.json.body" "$SNAP" << 'PY'
import json, sys
snap = sys.argv[2]
open(sys.argv[1], "w").write(json.dumps({
    "snapshot": snap,
    "labels": {"grux.factory": "1"},
    "autoStopInterval": 30,
}))
PY

create_status="$(curl -sS -o "$WORKDIR/create.json" -w '%{http_code}' \
  --max-time 120 \
  -X POST "$CREATE_URL" \
  -H "$AUTH_HEADER: Bearer ${DAYTONA_API_KEY}" \
  -H 'Content-Type: application/json' \
  --data-binary @"$WORKDIR/create.json.body")"

python3 - "$WORKDIR" "$create_status" << 'PY'
import json, sys
work, status = sys.argv[1], sys.argv[2]
raw = open(f"{work}/create.json", "rb").read()
try:
    body = json.loads(raw.decode())
except Exception:
    body = {}
if not isinstance(body, dict):
    body = {"_value": body}
ident = body.get("id") if isinstance(body.get("id"), str) else ""
open(f"{work}/id", "w").write(ident)
labels = body.get("labels") if isinstance(body.get("labels"), dict) else {}
auto = body.get("autoStopInterval")
token = ""
token_key = ""
for key, value in body.items():
    if not isinstance(value, str) or len(value) < 16:
        continue
    low = key.lower()
    if low == "token" or low.endswith("token"):
        token = value
        token_key = key
        break
open(f"{work}/toolbox-token", "w").write(token)
meta = {
    "createStatus": int(status),
    "idPrefix": ident[:8],
    "idLen": len(ident),
    "labelsAccepted": labels.get("grux.factory") in ("1", 1),
    "labelsEchoed": "labels" in body,
    "autoStopAccepted": auto == 30,
    "autoStopEchoed": "autoStopInterval" in body,
    "autoStopValue": auto if isinstance(auto, (int, float, str)) else None,
    "toolboxTokenKey": token_key,
    "responseKeys": sorted(body.keys()),
    "error": str(body.get("message") or body.get("error") or "")[:180],
}
open(f"{work}/create-meta.json", "w").write(json.dumps(meta))
print(json.dumps({k: meta[k] for k in ("createStatus", "idPrefix", "idLen", "labelsAccepted", "autoStopAccepted", "toolboxTokenKey", "error")}))
PY

ID="$(cat "$WORKDIR/id")"
if [[ -z "$ID" ]]; then
  echo "create failed, no sandbox id"
  cat "$WORKDIR/create-meta.json"
  exit 1
fi

EXEC_URL="${EXEC_TEMPLATE//\{id\}/$ID}"
DELETE_URL="${DELETE_TEMPLATE//\{id\}/$ID}"
python3 - "$WORKDIR/exec.json.body" "$CMD" "$TIMEOUT" << 'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({"command": sys.argv[2], "timeout": int(sys.argv[3])}))
PY

exec_once() {
  local header_value="$1"
  local out="$2"
  curl -sS -o "$out" -w '%{http_code}' \
    --max-time 90 \
    -X POST "$EXEC_URL" \
    -H "$AUTH_HEADER: Bearer ${header_value}" \
    -H 'Content-Type: application/json' \
    --data-binary @"$WORKDIR/exec.json.body" || echo "000"
}

EXEC_STATUS="$(exec_once "$DAYTONA_API_KEY" "$WORKDIR/exec.json")"
EXEC_AUTH="api-key"
if [[ "$EXEC_STATUS" == "401" || "$EXEC_STATUS" == "404" ]]; then
  TOOLBOX_TOKEN="$(cat "$WORKDIR/toolbox-token")"
  if [[ -n "$TOOLBOX_TOKEN" ]]; then
    EXEC_STATUS="$(exec_once "$TOOLBOX_TOKEN" "$WORKDIR/exec-retry.json")"
    cp "$WORKDIR/exec-retry.json" "$WORKDIR/exec.json"
    EXEC_AUTH="toolbox-token"
  fi
fi

python3 - "$WORKDIR" "$EXEC_STATUS" "$EXEC_AUTH" << 'PY'
import json, sys
work, status, auth = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(f"{work}/exec.json", "rb").read()
try:
    body = json.loads(raw.decode())
except Exception:
    body = {}
if not isinstance(body, dict):
    body = {}
text = ""
for key in ("result", "stdout", "output", "artifacts"):
    value = body.get(key)
    if isinstance(value, str):
        text = value
        break
meta = {
    "execStatus": int(status) if status.isdigit() else 0,
    "execAuth": auth,
    "execKeys": sorted(body.keys()),
    "sawProbe": "factory-probe" in text or "factory-probe" in raw.decode(errors="replace"),
    "exitCode": body.get("exitCode"),
    "error": str(body.get("message") or body.get("error") or "")[:180],
}
open(f"{work}/exec-meta.json", "w").write(json.dumps(meta))
print(json.dumps(meta))
PY

delete_once() {
  local header_value="$1"
  local out="$2"
  curl -sS -o "$out" -w '%{http_code}' \
    --max-time 60 \
    -X DELETE "$DELETE_URL" \
    -H "$AUTH_HEADER: Bearer ${header_value}" || echo "000"
}

DELETE_STATUS="$(delete_once "$DAYTONA_API_KEY" "$WORKDIR/delete.json")"
DELETE_AUTH="api-key"
if [[ "$DELETE_STATUS" == "401" || "$DELETE_STATUS" == "404" ]]; then
  TOOLBOX_TOKEN="$(cat "$WORKDIR/toolbox-token")"
  if [[ -n "$TOOLBOX_TOKEN" ]]; then
    DELETE_STATUS="$(delete_once "$TOOLBOX_TOKEN" "$WORKDIR/delete-retry.json")"
    DELETE_AUTH="toolbox-token"
  fi
fi

LIST_STATUS="$(curl -sS -o "$WORKDIR/list.json" -w '%{http_code}' \
  --max-time 60 \
  -X GET "$LIST_URL" \
  -H "$AUTH_HEADER: Bearer ${DAYTONA_API_KEY}" || echo "000")"

python3 - "$WORKDIR" "$DELETE_STATUS" "$DELETE_AUTH" "$LIST_STATUS" "$CREATE_URL" "$EXEC_TEMPLATE" "$DELETE_TEMPLATE" "$LIST_URL" "$AUTH_HEADER" << 'PY'
import json, os, sys, urllib.request
work, delete_status, delete_auth, list_status, create_url, exec_t, delete_t, list_url, auth_name = sys.argv[1:]
raw = open(f"{work}/list.json", "rb").read()
try:
    body = json.loads(raw.decode())
except Exception:
    body = []
rows = body if isinstance(body, list) else []
if isinstance(body, dict):
    for key in ("sandboxes", "items", "data"):
        if isinstance(body.get(key), list):
            rows = body[key]
            break
left = []
for row in rows:
    if not isinstance(row, dict):
        continue
    labels = row.get("labels") if isinstance(row.get("labels"), dict) else {}
    if str(labels.get("grux.factory")) == "1" and isinstance(row.get("id"), str):
        left.append(row["id"])
open(f"{work}/leftover-ids", "w").write("\n".join(left))
create = json.loads(open(f"{work}/create-meta.json").read())
execm = json.loads(open(f"{work}/exec-meta.json").read())
summary = {
    "createURL": create_url,
    "execURLTemplate": exec_t,
    "deleteURLTemplate": delete_t,
    "listURL": list_url,
    "authHeaderName": auth_name,
    "createStatus": create["createStatus"],
    "execStatus": execm["execStatus"],
    "execAuth": execm["execAuth"],
    "deleteStatus": int(delete_status) if str(delete_status).isdigit() else 0,
    "deleteAuth": delete_auth,
    "listStatus": int(list_status) if str(list_status).isdigit() else 0,
    "idPrefix": create["idPrefix"],
    "labelsAccepted": create["labelsAccepted"],
    "autoStopAccepted": create["autoStopAccepted"],
    "sawProbe": execm["sawProbe"],
    "exitCode": execm["exitCode"],
    "leftover": len(left),
    "createError": create["error"],
    "execError": execm["error"],
    "responseKeys": create["responseKeys"],
    "toolboxTokenKey": create["toolboxTokenKey"],
}
open("/tmp/grux-factory-probe-summary.json", "w").write(json.dumps(summary, indent=2))
os.chmod("/tmp/grux-factory-probe-summary.json", 0o600)
print(json.dumps(summary))
PY

# One delete pass for anything the list still marks. Not a retry loop.
if [[ -s "$WORKDIR/leftover-ids" ]]; then
  while IFS= read -r left_id; do
    [[ -z "$left_id" ]] && continue
    curl -sS -o /dev/null -w '' --max-time 60 \
      -X DELETE "https://app.daytona.io/api/sandbox/${left_id}" \
      -H "$AUTH_HEADER: Bearer ${DAYTONA_API_KEY}" || true
  done < "$WORKDIR/leftover-ids"
fi

LAST4="${DAYTONA_API_KEY: -4}"
echo "key last-4: ${LAST4}"
