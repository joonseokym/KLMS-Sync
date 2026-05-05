#!/usr/bin/env python3

from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

from klms_transport import (
    load_json,
    looks_like_login_page_payload,
    now_utc_iso,
    page_fingerprint,
    page_requested_url,
    parse_iso_datetime,
    read_url_inputs,
    write_json,
    write_text,
)

DEFAULT_CACHE_STATE = {"version": 1, "contexts": {}}
DEFAULT_SAFARI_FETCH_LOCK = Path("/tmp/klms-safari-fetch.lock")


def project_root() -> Path:
    return Path(__file__).resolve().parents[2]


def page_has_usable_html(page: dict[str, Any]) -> bool:
    return bool(str(page.get("html") or "").strip())


def main() -> int:
    run_started_epoch = time.time()
    run_started_at = now_utc_iso()
    parser = build_parser()
    args = parser.parse_args()

    urls = read_url_inputs(Path(args.url_file) if args.url_file else None, args.urls)
    if not urls:
        raise SystemExit("At least one URL is required.")

    out_path = Path(args.out).expanduser().resolve()
    cache_state_path = Path(args.cache_state).expanduser().resolve()
    backend = resolve_backend(args.backend)

    state = load_json(cache_state_path, DEFAULT_CACHE_STATE.copy()) or DEFAULT_CACHE_STATE.copy()
    contexts = state.setdefault("contexts", {})
    context_key = args.context or "default"
    context_state = contexts.setdefault(
        context_key,
        {
            "urls": {},
            "last_mode": "",
            "last_backend": "",
            "last_run_at": "",
            "last_full_at": "",
        },
    )

    previous_pages = [] if args.discard_previous else (load_json(out_path, []) if out_path.exists() else [])
    previous_lookup = {
        page_requested_url(page): page
        for page in previous_pages
        if (
            isinstance(page, dict)
            and page_requested_url(page)
            and page_has_usable_html(page)
            and not looks_like_login_page_payload(page)
        )
    }
    fallback_lookup = load_fallback_page_lookup(args.fallback_pages_json, urls)
    fallback_url_set = set(fallback_lookup)
    if fallback_lookup:
        previous_lookup.update({url: page for url, page in fallback_lookup.items() if url not in previous_lookup})
        seed_context_state_from_fallback(
            context_state=context_state,
            fallback_lookup=fallback_lookup,
            backend=backend,
        )

    effective_mode = resolve_mode(
        requested_mode=args.mode,
        urls=urls,
        previous_lookup=previous_lookup,
        context_state=context_state,
        full_ttl_seconds=args.full_ttl_seconds,
        auto_full_min_coverage=args.auto_full_min_coverage,
        auto_full_require_last_full=bool(args.auto_full_require_last_full),
        auto_full_on_ttl_expire=bool(args.auto_full_on_ttl_expire),
    )
    urls_to_fetch = choose_urls_to_fetch(
        urls=urls,
        previous_lookup=previous_lookup,
        context_state=context_state,
        mode=effective_mode,
        quick_limit=args.quick_limit,
        stale_seconds=args.stale_seconds,
        always_fetch_patterns=args.always_fetch_pattern or [],
        fallback_url_set=fallback_url_set if args.reuse_fallback_always_fetch else set(),
        probe_order=args.probe_order,
    )

    fetched_lookup: dict[str, dict[str, Any]] = {}
    fetched_url_list: list[str] = []
    changed_url_list: list[str] = []
    fetched_total = 0
    if urls_to_fetch:
        fetched_pages = fetch_pages_with_safari(
            urls=urls_to_fetch,
            wait_seconds=args.wait,
            min_wait_seconds=args.min_wait,
            stable_polls=args.stable_polls,
            script_dir=project_root(),
            telemetry_context=f"{context_key}:selected",
        )
        fetched_lookup = build_fetched_lookup(fetched_pages, previous_lookup, allow_login_pages=args.allow_login_pages)
        fetched_url_list.extend([url for url in urls_to_fetch if url in fetched_lookup])
        changed_url_list.extend(detect_changed_urls(fetched_lookup, previous_lookup))
        fetched_total += len(fetched_lookup)

    merged_pages = []
    missing_urls: list[str] = []
    for url in urls:
        if url in fetched_lookup:
            merged_pages.append(fetched_lookup[url])
            continue
        if url in previous_lookup:
            merged_pages.append(previous_lookup[url])
            continue
        missing_urls.append(url)

    if missing_urls:
        missing_pages = fetch_pages_with_safari(
            urls=missing_urls,
            wait_seconds=args.wait,
            min_wait_seconds=args.min_wait,
            stable_polls=args.stable_polls,
            script_dir=project_root(),
            telemetry_context=f"{context_key}:missing",
        )
        missing_lookup = build_fetched_lookup(missing_pages, previous_lookup, allow_login_pages=args.allow_login_pages)
        fetched_url_list.extend([url for url in missing_urls if url in missing_lookup])
        changed_url_list.extend(detect_changed_urls(missing_lookup, previous_lookup))
        fetched_total += len(missing_lookup)
        merged_pages = [missing_lookup.get(page_requested_url(page), page) for page in merged_pages]
        for url in missing_urls:
            page = missing_lookup.get(url)
            if page:
                merged_pages.append(page)

    ordered_lookup = {
        page_requested_url(page): page for page in merged_pages if page_requested_url(page)
    }
    final_pages = [ordered_lookup[url] for url in urls if url in ordered_lookup]

    update_context_state(
        context_state=context_state,
        pages=final_pages,
        backend=backend,
        effective_mode=effective_mode,
    )
    write_json(out_path, final_pages)
    write_json(cache_state_path, state)

    fetched_url_list = dedupe_preserving_order(fetched_url_list)
    changed_url_list = dedupe_preserving_order(changed_url_list)
    reused_url_list = [url for url in urls if url in ordered_lookup and url not in set(fetched_url_list)]
    summary = {
        "context": context_key,
        "backend": backend,
        "requested_mode": args.mode,
        "effective_mode": effective_mode,
        "started_at": run_started_at,
        "finished_at": now_utc_iso(),
        "duration_ms": int((time.time() - run_started_epoch) * 1000),
        "total_urls": len(urls),
        "fetched_urls": fetched_total,
        "reused_urls": len(reused_url_list),
        "changed_urls": len(changed_url_list),
        "out_path": str(out_path),
        "cache_state_path": str(cache_state_path),
    }
    if args.summary_out:
        summary_payload = dict(summary)
        summary_payload["fetched_url_list"] = fetched_url_list
        summary_payload["reused_url_list"] = reused_url_list
        summary_payload["changed_url_list"] = changed_url_list
        write_json(Path(args.summary_out).expanduser().resolve(), summary_payload)
    print(json.dumps(summary, ensure_ascii=False))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", default="safari")
    parser.add_argument("--mode", default="auto")
    parser.add_argument("--context", default="default")
    parser.add_argument("--wait", type=float, default=6.0)
    parser.add_argument("--min-wait", type=float, default=1.5)
    parser.add_argument("--stable-polls", type=int, default=2)
    parser.add_argument("--out", required=True)
    parser.add_argument("--cache-state", required=True)
    parser.add_argument("--summary-out")
    parser.add_argument("--url-file")
    parser.add_argument("--quick-limit", type=int, default=0)
    parser.add_argument("--probe-order", choices=["index", "oldest"], default="index")
    parser.add_argument("--stale-seconds", type=int, default=6 * 3600)
    parser.add_argument("--full-ttl-seconds", type=int, default=72 * 3600)
    parser.add_argument("--auto-full-min-coverage", type=float, default=0.5)
    parser.add_argument("--auto-full-require-last-full", type=int, choices=[0, 1], default=1)
    parser.add_argument("--auto-full-on-ttl-expire", type=int, choices=[0, 1], default=1)
    parser.add_argument("--always-fetch-pattern", action="append")
    parser.add_argument("--fallback-pages-json", action="append")
    parser.add_argument("--reuse-fallback-always-fetch", action="store_true")
    parser.add_argument("--allow-login-pages", action="store_true")
    parser.add_argument("--discard-previous", action="store_true")
    parser.add_argument("urls", nargs="*")
    return parser


def resolve_backend(requested_backend: str) -> str:
    backend = str(requested_backend or "safari").strip().lower()
    if backend in {"", "auto", "safari"}:
        return "safari"
    raise SystemExit(f"Unsupported backend: {backend}. Only Safari is supported.")


def resolve_mode(
    requested_mode: str,
    urls: list[str],
    previous_lookup: dict[str, dict[str, Any]],
    context_state: dict[str, Any],
    full_ttl_seconds: int,
    auto_full_min_coverage: float,
    auto_full_require_last_full: bool,
    auto_full_on_ttl_expire: bool,
) -> str:
    mode = str(requested_mode or "auto").strip().lower()
    if mode in {"full", "quick"}:
        return mode

    coverage_threshold = max(0.0, min(1.0, float(auto_full_min_coverage)))
    required_cached_count = 0
    if urls:
        required_cached_count = math.ceil(len(urls) * coverage_threshold)
        if coverage_threshold > 0:
            required_cached_count = max(1, required_cached_count)

    if not previous_lookup:
        return "full"
    if required_cached_count > 0 and len(previous_lookup) < required_cached_count:
        return "full"

    last_full_at = parse_iso_datetime(str(context_state.get("last_full_at") or ""))
    if auto_full_require_last_full and last_full_at is None:
        return "full"

    if auto_full_on_ttl_expire and last_full_at is not None:
        age_seconds = (parse_iso_datetime(now_utc_iso()) - last_full_at).total_seconds()
        if age_seconds >= max(0, full_ttl_seconds):
            return "full"
    elif auto_full_on_ttl_expire and auto_full_require_last_full and last_full_at is None:
        return "full"
    return "quick"


def choose_urls_to_fetch(
    urls: list[str],
    previous_lookup: dict[str, dict[str, Any]],
    context_state: dict[str, Any],
    mode: str,
    quick_limit: int,
    stale_seconds: int,
    always_fetch_patterns: list[str],
    fallback_url_set: set[str],
    probe_order: str,
) -> list[str]:
    if mode == "full":
        return [url for url in urls if url not in fallback_url_set]

    import re

    compiled_patterns = [re.compile(pattern) for pattern in always_fetch_patterns if pattern]
    now = parse_iso_datetime(now_utc_iso())
    selected: set[str] = set()
    url_state = context_state.get("urls", {})
    probe_candidates: list[tuple[float, int, str]] = []

    for index, url in enumerate(urls):
        previous_page = previous_lookup.get(url)
        metadata = url_state.get(url, {})

        if url in fallback_url_set and previous_page is not None and not looks_like_login_page_payload(previous_page):
            continue

        if any(pattern.search(url) for pattern in compiled_patterns):
            selected.add(url)
            continue

        if previous_page is None or looks_like_login_page_payload(previous_page):
            selected.add(url)
            continue

        fetched_at = parse_iso_datetime(str(metadata.get("last_fetched_at") or ""))
        if fetched_at is None or now is None:
            selected.add(url)
            continue

        if stale_seconds > 0 and (now - fetched_at).total_seconds() >= stale_seconds:
            selected.add(url)
            continue

        if probe_order == "oldest":
            probe_candidates.append((probe_priority(metadata), index, url))
            continue

        if quick_limit > 0 and index < quick_limit:
            selected.add(url)

    if quick_limit > 0 and probe_candidates:
        probe_candidates.sort()
        for _, _, url in probe_candidates[:quick_limit]:
            selected.add(url)

    return [url for url in urls if url in selected]


def probe_priority(metadata: dict[str, Any]) -> float:
    fetched_at = parse_iso_datetime(str(metadata.get("last_fetched_at") or ""))
    if fetched_at is None:
        return 0.0
    return fetched_at.timestamp()


def detect_changed_urls(
    fetched_lookup: dict[str, dict[str, Any]],
    previous_lookup: dict[str, dict[str, Any]],
) -> list[str]:
    changed_urls: list[str] = []
    for url, page in fetched_lookup.items():
        previous_page = previous_lookup.get(url)
        if previous_page is None or page_fingerprint(previous_page) != page_fingerprint(page):
            changed_urls.append(url)
    return changed_urls


def build_fetched_lookup(
    fetched_pages: list[dict[str, Any]],
    previous_lookup: dict[str, dict[str, Any]],
    allow_login_pages: bool = False,
) -> dict[str, dict[str, Any]]:
    lookup: dict[str, dict[str, Any]] = {}
    for page in fetched_pages:
        if not isinstance(page, dict):
            continue
        url = page_requested_url(page)
        if not url:
            continue
        previous_page = previous_lookup.get(url)
        if not allow_login_pages and looks_like_login_page_payload(page):
            continue
        lookup[url] = page
    return lookup


def load_fallback_page_lookup(paths: list[str] | None, requested_urls: list[str]) -> dict[str, dict[str, Any]]:
    requested = set(requested_urls)
    lookup: dict[str, dict[str, Any]] = {}
    for raw_path in paths or []:
        path = Path(raw_path).expanduser()
        if not path.exists():
            continue
        pages = load_json(path, [])
        if not isinstance(pages, list):
            continue
        for page in pages:
            if not isinstance(page, dict) or not page_has_usable_html(page):
                continue
            if looks_like_login_page_payload(page):
                continue
            url = page_requested_url(page)
            if url and url in requested and url not in lookup:
                lookup[url] = page
    return lookup


def seed_context_state_from_fallback(
    context_state: dict[str, Any],
    fallback_lookup: dict[str, dict[str, Any]],
    backend: str,
) -> None:
    if not fallback_lookup:
        return
    fetched_at = now_utc_iso()
    url_state = context_state.setdefault("urls", {})
    for url, page in fallback_lookup.items():
        html = str(page.get("html") or "")
        title = str(page.get("title") or "")
        fingerprint = page_fingerprint(page)
        previous_entry = url_state.get(url, {})
        url_state[url] = {
            "fingerprint": fingerprint,
            "title": title,
            "html_length": len(html),
            "last_fetched_at": str(previous_entry.get("last_fetched_at") or fetched_at),
            "last_changed_at": str(previous_entry.get("last_changed_at") or fetched_at),
            "backend": str(previous_entry.get("backend") or backend),
            "login_page": looks_like_login_page_payload(page),
        }


def dedupe_preserving_order(urls: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for url in urls:
        if not url or url in seen:
            continue
        seen.add(url)
        ordered.append(url)
    return ordered


def fetch_pages_with_safari(
    urls: list[str],
    wait_seconds: float,
    min_wait_seconds: float,
    stable_polls: int,
    script_dir: Path,
    telemetry_context: str = "fetch",
) -> list[dict[str, Any]]:
    def acquire_safari_fetch_lock() -> Any:
        lock_path = Path(
            str(
                os.environ.get("KLMS_SAFARI_FETCH_LOCK_PATH")
                or DEFAULT_SAFARI_FETCH_LOCK
            )
        ).expanduser()
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        handle = open(lock_path, "a+", encoding="utf-8")
        while True:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
                handle.seek(0)
                handle.truncate()
                handle.write(f"{os.getpid()} {time.time()}\n")
                handle.flush()
                return handle
            except InterruptedError:
                continue

    def fetch_once(
        batch_urls: list[str],
        attempt_wait_seconds: float,
        attempt_min_wait_seconds: float,
        attempt_stable_polls: int,
        attempt_index: int,
    ) -> list[dict[str, Any]]:
        with tempfile.TemporaryDirectory(prefix="klms-fetch-safari-") as temp_dir:
            temp_path = Path(temp_dir)
            out_path = temp_path / "pages.json"

            command = [
                "/usr/bin/osascript",
                "-l",
                "JavaScript",
                str((script_dir / "src/js/fetch_pages_with_safari.js").resolve()),
                f"--wait={attempt_wait_seconds}",
                f"--min-wait={attempt_min_wait_seconds}",
                f"--stable-polls={attempt_stable_polls}",
                f"--out={out_path}",
            ]
            command.extend(batch_urls)
            lock_handle = acquire_safari_fetch_lock()
            try:
                attempt_started = time.time()
                print(
                    json.dumps(
                        {
                            "context": telemetry_context,
                            "event": "safari-fetch-attempt-start",
                            "attempt": attempt_index,
                            "url_count": len(batch_urls),
                            "wait_seconds": attempt_wait_seconds,
                            "min_wait_seconds": attempt_min_wait_seconds,
                            "stable_polls": attempt_stable_polls,
                            "started_at": now_utc_iso(),
                        },
                        ensure_ascii=False,
                    ),
                    flush=True,
                )
                subprocess.run(command, cwd=str(script_dir), check=True)
            except subprocess.CalledProcessError:
                print(
                    json.dumps(
                        {
                            "context": telemetry_context,
                            "event": "safari-fetch-attempt-failed",
                            "attempt": attempt_index,
                            "url_count": len(batch_urls),
                            "finished_at": now_utc_iso(),
                            "duration_ms": int((time.time() - attempt_started) * 1000),
                        },
                        ensure_ascii=False,
                    ),
                    flush=True,
                )
                raise
            finally:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
                lock_handle.close()
            print(
                json.dumps(
                    {
                        "context": telemetry_context,
                        "event": "safari-fetch-attempt-finish",
                        "attempt": attempt_index,
                        "url_count": len(batch_urls),
                        "finished_at": now_utc_iso(),
                        "duration_ms": int((time.time() - attempt_started) * 1000),
                    },
                    ensure_ascii=False,
                ),
                flush=True,
            )
            payload = load_json(out_path, [])
            return [page for page in payload if isinstance(page, dict)]

    def fetch_batch_with_split(
        batch_urls: list[str],
        attempt_wait_seconds: float,
        attempt_min_wait_seconds: float,
        attempt_stable_polls: int,
        attempt_index: int,
    ) -> list[dict[str, Any]]:
        try:
            return fetch_once(
                batch_urls,
                attempt_wait_seconds,
                attempt_min_wait_seconds,
                attempt_stable_polls,
                attempt_index,
            )
        except subprocess.CalledProcessError:
            if len(batch_urls) <= 1:
                print(
                    json.dumps(
                        {
                            "context": telemetry_context,
                            "event": "safari-fetch-url-give-up",
                            "attempt": attempt_index,
                            "url": batch_urls[0] if batch_urls else "",
                            "finished_at": now_utc_iso(),
                        },
                        ensure_ascii=False,
                    ),
                    flush=True,
                )
                return []

            midpoint = max(1, len(batch_urls) // 2)
            left = fetch_batch_with_split(
                batch_urls[:midpoint],
                attempt_wait_seconds,
                attempt_min_wait_seconds,
                attempt_stable_polls,
                attempt_index,
            )
            right = fetch_batch_with_split(
                batch_urls[midpoint:],
                attempt_wait_seconds,
                attempt_min_wait_seconds,
                attempt_stable_polls,
                attempt_index,
            )
            return left + right

    ordered_urls = dedupe_preserving_order(urls)
    resolved_pages: dict[str, dict[str, Any]] = {}
    remaining_urls = list(ordered_urls)
    batch_size = max(1, int(os.environ.get("KLMS_FETCH_SAFARI_BATCH_SIZE") or "40"))
    retry_plan = [
        (wait_seconds, min_wait_seconds, stable_polls),
        (max(wait_seconds + 2.0, min_wait_seconds + 2.0), min_wait_seconds, max(stable_polls, 2)),
        (
            max(wait_seconds + 4.0, min_wait_seconds + 3.0),
            min(max(min_wait_seconds + 0.5, 2.0), max(wait_seconds + 4.0, min_wait_seconds + 3.0)),
            max(stable_polls + 1, 3),
        ),
    ]

    for attempt_index, (attempt_wait_seconds, attempt_min_wait_seconds, attempt_stable_polls) in enumerate(retry_plan, start=1):
        if not remaining_urls:
            break

        fetched_pages: list[dict[str, Any]] = []
        for batch_start in range(0, len(remaining_urls), batch_size):
            batch_urls = remaining_urls[batch_start : batch_start + batch_size]
            fetched_pages.extend(
                fetch_batch_with_split(
                    batch_urls,
                    attempt_wait_seconds,
                    attempt_min_wait_seconds,
                    attempt_stable_polls,
                    attempt_index,
                )
            )
        fetched_lookup = {
            page_requested_url(page): page
            for page in fetched_pages
            if page_requested_url(page)
        }

        next_remaining_urls: list[str] = []
        for url in remaining_urls:
            page = fetched_lookup.get(url)
            if page is None:
                next_remaining_urls.append(url)
                continue

            html = str(page.get("html") or "").strip()
            if not html:
                next_remaining_urls.append(url)
                continue

            resolved_pages[url] = page

        remaining_urls = next_remaining_urls

    return [resolved_pages[url] for url in ordered_urls if url in resolved_pages]


def update_context_state(
    context_state: dict[str, Any],
    pages: list[dict[str, Any]],
    backend: str,
    effective_mode: str,
) -> None:
    fetched_at = now_utc_iso()
    url_state = context_state.setdefault("urls", {})
    for page in pages:
        requested_url = page_requested_url(page)
        if not requested_url:
            continue
        html = str(page.get("html") or "")
        title = str(page.get("title") or "")
        fingerprint = page_fingerprint(page)
        previous_entry = url_state.get(requested_url, {})
        url_state[requested_url] = {
            "fingerprint": fingerprint,
            "title": title,
            "html_length": len(html),
            "last_fetched_at": fetched_at,
            "last_changed_at": (
                fetched_at
                if previous_entry.get("fingerprint") != fingerprint
                else str(previous_entry.get("last_changed_at") or "")
            ),
            "backend": backend,
            "login_page": looks_like_login_page_payload(page),
        }

    context_state["last_mode"] = effective_mode
    context_state["last_backend"] = backend
    context_state["last_run_at"] = fetched_at
    if effective_mode == "full":
        context_state["last_full_at"] = fetched_at


if __name__ == "__main__":
    raise SystemExit(main())
