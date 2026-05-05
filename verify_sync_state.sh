#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMON_SH="$SCRIPT_DIR/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_init_context "$0" "${1:-}"
STATE_JSON="$SCRIPT_DIR/runtime/state/state.json"

python3 - "$CACHE_DIR" "$STATE_JSON" <<'PY'
import json
import os
import sys
from pathlib import Path

cache_dir = Path(sys.argv[1])
state_json = Path(sys.argv[2])

notice_digest = json.loads((cache_dir / "notice_digest.json").read_text())
notice_primary = json.loads((cache_dir / "notice_note_render_state.json").read_text())
notice_archive = json.loads((cache_dir / "notice_archive_note_render_state.json").read_text())
state = json.loads(state_json.read_text())
manifest = json.loads((cache_dir / "course_file_manifest.json").read_text())

digest_urls = []
for course in notice_digest.get("courses", []):
    for notice in course.get("notices", []):
        url = notice.get("url")
        if url:
            digest_urls.append(url)

rendered_urls = set()
for render_state in (notice_primary, notice_archive):
    for item in render_state.get("rendered_notices", []):
        url = item.get("notice_id")
        if url:
            rendered_urls.add(url)

missing_notice_urls = sorted(set(digest_urls) - rendered_urls)

missing_files = []
for item in manifest:
    absolute_path = item.get("absolute_path")
    relative_path = item.get("relative_path", "")
    if not absolute_path or not os.path.isfile(absolute_path):
        missing_files.append(relative_path or absolute_path or "<unknown>")

content = state.get("content", {}) if isinstance(state, dict) else {}
exam_items = content.get("exam_items", []) if isinstance(content, dict) else []
helpdesk_items = content.get("help_desk_items", []) if isinstance(content, dict) else []
assignments = content.get("assignments", []) if isinstance(content, dict) else []

print(f"notice_digest_count={len(digest_urls)}")
print(f"notice_rendered_count={len(rendered_urls)}")
print(f"notice_missing_count={len(missing_notice_urls)}")
for url in missing_notice_urls:
    print(f"notice_missing_url={url}")

print(f"manifest_file_count={len(manifest)}")
print(f"manifest_missing_file_count={len(missing_files)}")
for path in missing_files:
    print(f"manifest_missing_file={path}")

print(f"state_assignment_count={len(assignments)}")
print(f"state_exam_count={len(exam_items)}")
for item in exam_items:
    print(f"state_exam={item.get('course','')} | {item.get('title','')} | {item.get('due','')}")
print(f"state_helpdesk_count={len(helpdesk_items)}")
for item in helpdesk_items:
    print(f"state_helpdesk={item.get('course','')} | {item.get('title','')} | {item.get('due','')}")
PY

calendar_exam_summaries="$(osascript -e 'tell application "Calendar" to return summary of every event of calendar "시험"')"
calendar_helpdesk_summaries="$(osascript -e 'tell application "Calendar" to return summary of every event of calendar "기타"')"
calendar_names="$(osascript -e 'tell application "Calendar" to return name of every calendar')"

python3 - "$calendar_exam_summaries" "$calendar_helpdesk_summaries" "$calendar_names" <<'PY'
import sys

exam_summaries = [item.strip() for item in sys.argv[1].split(",") if item.strip()]
helpdesk_summaries = [item.strip() for item in sys.argv[2].split(",") if item.strip()]
calendar_names = {item.strip() for item in sys.argv[3].split(",") if item.strip()}

exam_count = sum(1 for item in exam_summaries if item.startswith("[KLMS 시험]"))
helpdesk_count = sum(1 for item in helpdesk_summaries if item.startswith("[KLMS 헬프데스크]"))

print(f"calendar_exam_count={exam_count}")
print(f"calendar_helpdesk_count={helpdesk_count}")
print(f"legacy_calendar_assignment_exists={'true' if 'KLMS 과제' in calendar_names else 'false'}")
print(f"legacy_calendar_alert_exists={'true' if 'KLMS 알림' in calendar_names else 'false'}")
PY
