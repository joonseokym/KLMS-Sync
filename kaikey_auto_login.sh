#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KLMS_JS_DIR="$SCRIPT_DIR/src/js"
CONFIG_PATH="${1:-$SCRIPT_DIR/config.env}"

if [[ -f "$CONFIG_PATH" ]]; then
  source "$CONFIG_PATH"
fi

KLMS_LOGIN_URL="${KLMS_LOGIN_URL:-${KLMS_DASHBOARD_URL:-https://klms.kaist.ac.kr/my/}}"
KAIKEY_AUTO_LOGIN_TIMEOUT_SECONDS="${KAIKEY_AUTO_LOGIN_TIMEOUT_SECONDS:-90}"
KAIKEY_AUTO_LOGIN_POLL_SECONDS="${KAIKEY_AUTO_LOGIN_POLL_SECONDS:-1}"
KAIKEY_APPROVE_ATTEMPTS="${KAIKEY_APPROVE_ATTEMPTS:-5}"
KAIKEY_APPROVE_INTERVAL_MS="${KAIKEY_APPROVE_INTERVAL_MS:-1500}"
KAIKEY_STATE_PATH="${KAIKEY_STATE_PATH:-$HOME/Library/Application Support/KLMSNotesSync/kaikey_state.json}"
export KAIKEY_STATE_PATH

resolve_node_bin() {
  if [[ -n "${KAIKEY_NODE_BIN:-}" && -x "$KAIKEY_NODE_BIN" ]]; then
    print -r -- "$KAIKEY_NODE_BIN"
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    command -v node
    return 0
  fi
  if [[ -x /opt/homebrew/bin/node ]]; then
    print -r -- /opt/homebrew/bin/node
    return 0
  fi
  if [[ -x /usr/local/bin/node ]]; then
    print -r -- /usr/local/bin/node
    return 0
  fi
  return 1
}

json_get() {
  local json="$1"
  local key="$2"
  local python_bin="${KLMS_PYTHON_BIN:-python3}"
  printf '%s' "$json" | "$python_bin" -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$key"
}

NODE_BIN="$(resolve_node_bin)" || {
  print -r -- "status=skipped reason=node-not-found"
  exit 2
}

"$NODE_BIN" "$KLMS_JS_DIR/kaikey_cli.mjs" status >/dev/null 2>&1 || {
  print -r -- "status=skipped reason=kaikey-not-registered"
  exit 2
}

DISPLAY_NAME="$("$NODE_BIN" "$KLMS_JS_DIR/kaikey_cli.mjs" identity)"
deadline_epoch="$(( $(date +%s) + KAIKEY_AUTO_LOGIN_TIMEOUT_SECONDS ))"
last_status=""

while (( $(date +%s) < deadline_epoch )); do
  step_json="$(/usr/bin/osascript -l JavaScript "$KLMS_JS_DIR/kaikey_safari_step.js" \
    "--url=$KLMS_LOGIN_URL" \
    "--display-name=$DISPLAY_NAME" 2>/dev/null || true)"

  if [[ -z "$step_json" ]]; then
    sleep "$KAIKEY_AUTO_LOGIN_POLL_SECONDS"
    continue
  fi

  step_status="$(json_get "$step_json" status 2>/dev/null || true)"
  last_status="$step_status"

  case "$step_status" in
    authenticated)
      print -r -- "status=ok stage=authenticated"
      exit 0
      ;;
    twofactor_digits)
      digits="$(json_get "$step_json" digits 2>/dev/null || true)"
      if [[ "$digits" == <-> && "${#digits}" == "2" ]]; then
        approve_json="$("$NODE_BIN" "$KLMS_JS_DIR/kaikey_cli.mjs" approve-if-match \
          "--digits=$digits" \
          "--attempts=$KAIKEY_APPROVE_ATTEMPTS" \
          "--interval-ms=$KAIKEY_APPROVE_INTERVAL_MS" 2>/dev/null || true)"
        approved="$(json_get "$approve_json" approved 2>/dev/null || true)"
        if [[ "$approved" == "True" || "$approved" == "true" ]]; then
          sleep 4
        else
          reason="$(json_get "$approve_json" reason 2>/dev/null || true)"
          print -r -- "status=failed stage=approve reason=${reason:-unknown}"
          exit 1
        fi
      fi
      ;;
    navigated|klms_redirect_clicked|login_submitted|waiting)
      ;;
    error)
      reason="$(json_get "$step_json" error 2>/dev/null || true)"
      print -r -- "status=failed stage=safari reason=${reason:-unknown}"
      exit 1
      ;;
  esac

  sleep "$KAIKEY_AUTO_LOGIN_POLL_SECONDS"
done

print -r -- "status=timeout last_status=${last_status:-unknown}"
exit 1
