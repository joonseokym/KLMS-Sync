#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

UTC = timezone.utc
SEOUL = timezone(timedelta(hours=9))


def now_utc_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    normalized = str(value).strip()
    if not normalized:
        return None
    if normalized.endswith("Z"):
        normalized = f"{normalized[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def normalize_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").replace("\xa0", " ")).strip()


def load_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Any) -> None:
    write_text(
        path,
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
    )


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=str(path.parent),
            delete=False,
        ) as handle:
            handle.write(content)
            temp_path = Path(handle.name)
        os.replace(temp_path, path)
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink(missing_ok=True)


def page_requested_url(page: dict[str, Any]) -> str:
    return str(page.get("requestedUrl") or page.get("url") or "").strip()


def page_fingerprint(page: dict[str, Any]) -> str:
    requested_url = page_requested_url(page)
    title = str(page.get("title") or "")
    html = str(page.get("html") or "")
    digest = hashlib.sha256()
    digest.update(requested_url.encode("utf-8"))
    digest.update(b"\0")
    digest.update(title.encode("utf-8"))
    digest.update(b"\0")
    digest.update(html.encode("utf-8"))
    return digest.hexdigest()


def looks_like_login_page(url: str, title: str, html: str) -> bool:
    url_lower = (url or "").lower()
    title_lower = (title or "").lower()
    if "login" in url_lower or "portal.kaist.ac.kr" in url_lower:
        return True
    if "log in" in title_lower or "single sign on" in title_lower:
        return True
    html_lower = (html or "").lower()
    if "action=\"https://portal.kaist.ac.kr" in html_lower:
        return True
    return False


def looks_like_login_page_payload(page: dict[str, Any]) -> bool:
    requested_url = page_requested_url(page)
    final_url = str(page.get("url") or page.get("finalUrl") or "").strip()
    title = str(page.get("title") or "")
    html = str(page.get("html") or "")
    return (
        looks_like_login_page(requested_url, title, html)
        or looks_like_login_page(final_url, title, html)
        or "login/ssologin.php" in html.lower()
    )


def read_url_inputs(url_file: Path | None, inline_urls: Iterable[str]) -> list[str]:
    urls: list[str] = []
    seen: set[str] = set()

    def append(raw: str) -> None:
        value = str(raw or "").strip()
        if not value or value in seen:
            return
        seen.add(value)
        urls.append(value)

    if url_file and url_file.exists():
        for line in url_file.read_text(encoding="utf-8").splitlines():
            append(line)

    for inline_url in inline_urls:
        append(inline_url)

    return urls
