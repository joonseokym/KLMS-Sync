#!/bin/zsh

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KLMS_SH_DIR="$SCRIPT_DIR/src/sh"
KLMS_JS_DIR="$SCRIPT_DIR/src/js"
CONFIG_PATH="$SCRIPT_DIR/config.env"
RUNTIME_DIR="$SCRIPT_DIR/runtime"
AUTOMATION_DIR="$RUNTIME_DIR/automation"
LOG_DIR="$RUNTIME_DIR/logs"
LOCK_DIR="$AUTOMATION_DIR/launch.lock"
LAST_ATTEMPT_FILE="$AUTOMATION_DIR/last_attempt_epoch"
ALERT_STATE_FILE="$AUTOMATION_DIR/reminder_alert_state.json"
LOGIN_PROMPT_EPOCH_FILE="$AUTOMATION_DIR/login_prompt_epoch"
LOGIN_WATCH_LOCK_DIR="$AUTOMATION_DIR/login-watch.lock"
LAUNCH_LOG="$LOG_DIR/launch-agent.log"
NEXT_STATE_FILE="$RUNTIME_DIR/state/next_state.json"
STATE_FILE="$RUNTIME_DIR/state/state.json"

mkdir -p "$AUTOMATION_DIR" "$LOG_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

source "$CONFIG_PATH"

KLMS_LOGIN_URL="${KLMS_LOGIN_URL:-${KLMS_DASHBOARD_URL:-https://klms.kaist.ac.kr/my/}}"
LOGIN_PROMPT_COOLDOWN_SECONDS="${LOGIN_PROMPT_COOLDOWN_SECONDS:-3600}"
LOGIN_PROMPT_OPEN_SAFARI="${LOGIN_PROMPT_OPEN_SAFARI:-0}"
MACOS_REMINDER_NOTIFICATIONS_ENABLED="${MACOS_REMINDER_NOTIFICATIONS_ENABLED:-0}"

reset_login_prompt_state() {
  rm -f "$LOGIN_PROMPT_EPOCH_FILE"
}

has_login_error() {
  local sync_output="$1"
  local candidate=""

  if [[ "$sync_output" == *"로그인"* ]]; then
    return 0
  fi

  if [[ -f "$NEXT_STATE_FILE" ]]; then
    candidate="$NEXT_STATE_FILE"
  elif [[ -f "$STATE_FILE" ]]; then
    candidate="$STATE_FILE"
  else
    return 1
  fi

  grep -q '로그인' "$candidate"
}

prompt_login_if_needed() {
  local prompt_now_epoch
  local last_prompt=0
  local timestamp

  prompt_now_epoch="$(date +%s)"
  if [[ -f "$LOGIN_PROMPT_EPOCH_FILE" ]]; then
    last_prompt="$(<"$LOGIN_PROMPT_EPOCH_FILE")"
  fi

  if [[ "$last_prompt" == <-> ]] && (( prompt_now_epoch - last_prompt < LOGIN_PROMPT_COOLDOWN_SECONDS )); then
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '[%s] login-prompt suppressed cooldown=%ss\n' "$timestamp" "$LOGIN_PROMPT_COOLDOWN_SECONDS" >> "$LAUNCH_LOG"
    return 0
  fi

  /usr/bin/osascript -e 'display notification "Safari에서 KLMS 로그인과 OTP 승인을 진행해 주세요." with title "KLMS 동기화"' >/dev/null 2>&1 || true
  if [[ "$LOGIN_PROMPT_OPEN_SAFARI" == "1" ]]; then
    /usr/bin/osascript \
      -e 'on run argv' \
      -e 'set targetUrl to item 1 of argv' \
      -e 'tell application "Safari" to make new document with properties {URL:targetUrl}' \
      -e 'end run' \
      "$KLMS_LOGIN_URL" >/dev/null 2>&1 || true
  fi
  print -r -- "$prompt_now_epoch" > "$LOGIN_PROMPT_EPOCH_FILE"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '[%s] login-prompt notified backend=%s open_safari=%s url=%s\n' \
    "$timestamp" "safari" "$LOGIN_PROMPT_OPEN_SAFARI" "$KLMS_LOGIN_URL" >> "$LAUNCH_LOG"
}

start_login_watch_if_needed() {
  local timestamp

  if [[ -d "$LOGIN_WATCH_LOCK_DIR" ]]; then
    return 0
  fi

  nohup /bin/zsh "$KLMS_SH_DIR/watch_klms_login_recovery.sh" >/dev/null 2>&1 &
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '[%s] login-watch spawn pid=%s\n' "$timestamp" "$!" >> "$LAUNCH_LOG"
}

timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ "$MACOS_REMINDER_NOTIFICATIONS_ENABLED" == "1" ]]; then
  alert_output="$(cd "$SCRIPT_DIR" && osascript -l JavaScript "$KLMS_JS_DIR/notify_klms_reminders.js" ./config.env "$ALERT_STATE_FILE" 2>&1)" || true
  printf '[%s] alerts %s\n' "$timestamp" "$alert_output" >> "$LAUNCH_LOG"
else
  printf '[%s] alerts status=skipped macos-reminder-notifications-disabled\n' "$timestamp" >> "$LAUNCH_LOG"
fi

SYNC_INTERVAL_SECONDS="${SYNC_INTERVAL_SECONDS:-21600}"
MIN_IDLE_SECONDS="${MIN_IDLE_SECONDS:-600}"

now_epoch="$(date +%s)"
last_attempt=0
if [[ -f "$LAST_ATTEMPT_FILE" ]]; then
  last_attempt="$(<"$LAST_ATTEMPT_FILE")"
fi

if [[ "$last_attempt" == <-> ]] && (( now_epoch - last_attempt < SYNC_INTERVAL_SECONDS )); then
  exit 0
fi

idle_seconds="$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')"
if [[ -z "$idle_seconds" || "$idle_seconds" != <-> ]]; then
  idle_seconds=0
fi

if (( idle_seconds < MIN_IDLE_SECONDS )); then
  exit 0
fi

print -r -- "$now_epoch" > "$LAST_ATTEMPT_FILE"

timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
set +e
sync_output="$(cd "$SCRIPT_DIR" && /bin/zsh ./run_all.sh ./config.env 2>&1)"
sync_exit=$?
set -e
printf '[%s] idle=%ss exit=%s %s\n' "$timestamp" "$idle_seconds" "$sync_exit" "$sync_output" >> "$LAUNCH_LOG"

if (( sync_exit == 0 )); then
  reset_login_prompt_state
  exit 0
fi

if has_login_error "$sync_output"; then
  # Login expiry should retry again on the next 15-minute wake so the sync
  # can recover shortly after the user finishes Safari OTP approval.
  print -r -- "0" > "$LAST_ATTEMPT_FILE"
  start_login_watch_if_needed
  prompt_login_if_needed
else
  /usr/bin/osascript -e 'display notification "KLMS 동기화가 실패했어요. 로그를 확인해 주세요." with title "KLMS 동기화"' >/dev/null 2>&1 || true
fi
