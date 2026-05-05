#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KLMS_SWIFT_DIR="$SCRIPT_DIR/src/swift"
MODULE_CACHE_DIR="/tmp/klms-swift-module-cache"
BUILD_DIR="/tmp/klms-notice-native-note-build"
BIN_PATH="$BUILD_DIR/update_notice_native_note"
MAX_ATTEMPTS="${NOTICE_NATIVE_NOTE_MAX_ATTEMPTS:-3}"
RETRY_DELAY_SECONDS="${NOTICE_NATIVE_NOTE_RETRY_DELAY_SECONDS:-1}"
TIMEOUT_SECONDS="${NOTICE_NATIVE_NOTE_TIMEOUT_SECONDS:-180}"
TIMEOUT_GRACE_SECONDS="${NOTICE_NATIVE_NOTE_TIMEOUT_GRACE_SECONDS:-3}"
TIMING_LOG="${NOTICE_NATIVE_NOTE_TIMING_LOG:-$SCRIPT_DIR/runtime/cache/notice_native_note_timing.log}"
DEFAULT_XCODE_SWIFTC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
DEFAULT_XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
SWIFT_SOURCES=(
  "$KLMS_SWIFT_DIR/notice_native_note_support.swift"
  "$KLMS_SWIFT_DIR/update_notice_native_note.swift"
)

mkdir -p "$MODULE_CACHE_DIR"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
mkdir -p "$BUILD_DIR"

timestamp_now() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

log_timing() {
  mkdir -p "$(dirname "$TIMING_LOG")"
  printf '%s\t%s\n' "$(timestamp_now)" "$*" >> "$TIMING_LOG"
}

if [[ -x "$DEFAULT_XCODE_SWIFTC" ]]; then
  SWIFTC_BIN="$DEFAULT_XCODE_SWIFTC"
  if [[ -d "$DEFAULT_XCODE_SDK" ]]; then
    SWIFTC_ARGS=(-sdk "$DEFAULT_XCODE_SDK")
  else
    SWIFTC_ARGS=()
  fi
else
  SWIFTC_BIN="$(command -v swiftc)"
  SWIFTC_ARGS=()
fi

NOTE_TITLE="KLMS 공지"
PASS_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --note-title)
      NOTE_TITLE="${2:-$NOTE_TITLE}"
      PASS_ARGS+=("$1" "$NOTE_TITLE")
      shift 2
      ;;
    *)
      PASS_ARGS+=("$1")
      shift
      ;;
  esac
done

needs_build=0
if [[ ! -x "$BIN_PATH" ]]; then
  needs_build=1
else
  for source_path in "${SWIFT_SOURCES[@]}"; do
    if [[ "$source_path" -nt "$BIN_PATH" ]]; then
      needs_build=1
      break
    fi
  done
fi

if (( needs_build )); then
  tmp_bin="$BIN_PATH.tmp.$$"
  "$SWIFTC_BIN" "${SWIFTC_ARGS[@]}" "${SWIFT_SOURCES[@]}" -o "$tmp_bin"
  mv "$tmp_bin" "$BIN_PATH"
fi

run_native_note_once() {
  local timeout_flag="$BUILD_DIR/update_notice_native_note.timeout.$$.$RANDOM"
  local watchdog_pid=""
  local started_epoch
  local finished_epoch
  local duration_s
  rm -f "$timeout_flag"

  "$BIN_PATH" "${PASS_ARGS[@]}" &
  local target_pid=$!
  started_epoch="$(date +%s)"
  log_timing "attempt_start pid=$target_pid timeout_s=$TIMEOUT_SECONDS args=${PASS_ARGS[*]}"

  if [[ "$TIMEOUT_SECONDS" -gt 0 ]]; then
    (
      sleep "$TIMEOUT_SECONDS"
      if kill -0 "$target_pid" >/dev/null 2>&1; then
        : > "$timeout_flag"
        kill -TERM "$target_pid" >/dev/null 2>&1 || true
        sleep "$TIMEOUT_GRACE_SECONDS"
        kill -KILL "$target_pid" >/dev/null 2>&1 || true
      fi
    ) >/dev/null 2>&1 &
    watchdog_pid=$!
  fi

  local exit_status=0
  set +e
  wait "$target_pid"
  exit_status=$?
  set -e

  if [[ -n "$watchdog_pid" ]]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" >/dev/null 2>&1 || true
  fi

  finished_epoch="$(date +%s)"
  duration_s=$((finished_epoch - started_epoch))

  if [[ -f "$timeout_flag" ]]; then
    rm -f "$timeout_flag"
    log_timing "attempt_finish pid=$target_pid result=timeout exit_status=$exit_status duration_s=$duration_s"
    return 124
  fi

  log_timing "attempt_finish pid=$target_pid result=exit exit_status=$exit_status duration_s=$duration_s"
  return "$exit_status"
}

attempt=1
while true; do
  set +e
  run_native_note_once
  attempt_status=$?
  set -e
  if [[ "$attempt_status" -eq 0 ]]; then
    exit 0
  fi

  if (( attempt >= MAX_ATTEMPTS )); then
    exit "$attempt_status"
  fi

  if [[ "$attempt_status" -eq 124 ]]; then
    printf 'update_notice_native_note attempt %d/%d timed out after %ss; retrying in %ss\n' \
      "$attempt" \
      "$MAX_ATTEMPTS" \
      "$TIMEOUT_SECONDS" \
      "$RETRY_DELAY_SECONDS" \
      >&2
  else
    printf 'update_notice_native_note attempt %d/%d failed with exit %d; retrying in %ss\n' \
      "$attempt" \
      "$MAX_ATTEMPTS" \
      "$attempt_status" \
      "$RETRY_DELAY_SECONDS" \
      >&2
  fi
  sleep "$RETRY_DELAY_SECONDS"
  attempt=$((attempt + 1))
done
