#!/bin/zsh

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KLMS_JS_DIR="$SCRIPT_DIR/src/js"
CONFIG_PATH="$SCRIPT_DIR/config.env"
RUNTIME_DIR="$SCRIPT_DIR/runtime"
AUTOMATION_DIR="$RUNTIME_DIR/automation"
LOG_DIR="$RUNTIME_DIR/logs"
LOCK_DIR="$AUTOMATION_DIR/login-watch.lock"
LAST_ATTEMPT_FILE="$AUTOMATION_DIR/last_attempt_epoch"
LOGIN_PROMPT_EPOCH_FILE="$AUTOMATION_DIR/login_prompt_epoch"
LAUNCH_LOG="$LOG_DIR/launch-agent.log"

mkdir -p "$AUTOMATION_DIR" "$LOG_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

source "$CONFIG_PATH"

LOGIN_WATCH_TIMEOUT_SECONDS="${LOGIN_WATCH_TIMEOUT_SECONDS:-1200}"
LOGIN_WATCH_POLL_SECONDS="${LOGIN_WATCH_POLL_SECONDS:-5}"
LOGIN_WATCH_RETRY_SECONDS="${LOGIN_WATCH_RETRY_SECONDS:-30}"

looks_like_login_page() {
  local url_lower="${1:l}"
  local title_lower="${2:l}"

  [[ "$url_lower" == *"login"* ]] \
    || [[ "$url_lower" == *"portal.kaist.ac.kr"* ]] \
    || [[ "$title_lower" == *"log in"* ]] \
    || [[ "$title_lower" == *"single sign on"* ]]
}

timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf '[%s] login-watch started timeout=%ss poll=%ss\n' \
  "$timestamp" "$LOGIN_WATCH_TIMEOUT_SECONDS" "$LOGIN_WATCH_POLL_SECONDS" >> "$LAUNCH_LOG"

deadline_epoch="$(( $(date +%s) + LOGIN_WATCH_TIMEOUT_SECONDS ))"
last_sync_attempt=0

while (( $(date +%s) < deadline_epoch )); do
  tabs_json="$(cd "$SCRIPT_DIR" && /usr/bin/osascript -l JavaScript "$KLMS_JS_DIR/inspect_klms_tabs.js" 2>/dev/null)" || tabs_json='{}'
  page_status="$(printf '%s' "$tabs_json" | /usr/bin/jq -r '.status // "error"' 2>/dev/null)"

  if [[ "$page_status" == "ok" ]]; then
    authenticated_url="$(printf '%s' "$tabs_json" \
      | /usr/bin/jq -r '
          (.tabs // [])
          | map(select((.url // "" | ascii_downcase | contains("klms.kaist.ac.kr")) and ((.url // "" | ascii_downcase | contains("login")) | not) and ((.url // "" | ascii_downcase | contains("portal.kaist.ac.kr")) | not) and ((.title // "" | ascii_downcase | contains("log in")) | not) and ((.title // "" | ascii_downcase | contains("single sign on")) | not)))
          | .[0].url // ""
        ' 2>/dev/null)"
    now_epoch="$(date +%s)"

    if [[ -n "$authenticated_url" ]] && (( now_epoch - last_sync_attempt >= LOGIN_WATCH_RETRY_SECONDS )); then
      last_sync_attempt="$now_epoch"
      timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
      printf '[%s] login-watch detected authenticated tab %s\n' "$timestamp" "$authenticated_url" >> "$LAUNCH_LOG"

      sync_output="$(cd "$SCRIPT_DIR" && /bin/zsh ./sync_klms_core.sh ./config.env 2>&1)" || true
      timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
      printf '[%s] login-watch sync %s\n' "$timestamp" "$sync_output" >> "$LAUNCH_LOG"

      if [[ "$sync_output" == status=ok* ]]; then
        rm -f "$LOGIN_PROMPT_EPOCH_FILE"
        print -r -- "$now_epoch" > "$LAST_ATTEMPT_FILE"
        exit 0
      fi

      if [[ "$sync_output" != *"로그인"* ]]; then
        exit 0
      fi
    fi
  fi

  sleep "$LOGIN_WATCH_POLL_SECONDS"
done

timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf '[%s] login-watch timed out\n' "$timestamp" >> "$LAUNCH_LOG"
