"""Discover public human-read recordings through the official LibriVox catalog."""

import asyncio
import json
import re
import time
from collections import OrderedDict
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from urllib.parse import quote, unquote, urlsplit, urlunsplit

import httpx
from fastapi import APIRouter, HTTPException, Query
from lxml import etree, html

LIBRIVOX_URL = "https://librivox.org"
RIGHTS_URL = f"{LIBRIVOX_URL}/pages/public-domain/"
MAX_RESPONSE_BYTES = 4_000_000
MAX_TRACKS = 1_500
MAX_OPEN_REQUESTS = 4
MAX_CACHE_ENTRIES = 96
MIN_REQUEST_INTERVAL = 3
SEARCH_TTL = 15 * 60
BOOK_TTL = 6 * 60 * 60
STALE_TTL = 24 * 60 * 60
USER_AGENT = "TheTeller/1.0 (LibriVox catalog integration)"

router = APIRouter(prefix="/api/catalog/human", tags=["human audiobooks"])


class UpstreamUnavailable(Exception):
    pass


class CatalogClient:
    def __init__(self):
        self._cache = OrderedDict()
        self._pending = {}
        self._request_lock = asyncio.Lock()
        self._next_request = 0.0
        self._retry_at = 0.0

    async def _get(self, path, params=None, *, json_response=True):
        async with self._request_lock:
            if time.monotonic() < self._retry_at:
                raise UpstreamUnavailable
            await asyncio.sleep(max(0, self._next_request - time.monotonic()))
            self._next_request = time.monotonic() + MIN_REQUEST_INTERVAL
            try:
                async with asyncio.timeout(8):
                    async with httpx.AsyncClient(
                        base_url=LIBRIVOX_URL,
                        follow_redirects=False,
                        trust_env=False,
                        headers={
                            "User-Agent": USER_AGENT,
                            "Accept-Encoding": "identity",
                            "Accept": "application/json" if json_response else "application/rss+xml, application/xml, text/xml",
                        },
                    ) as client:
                        async with client.stream("GET", path, params=params) as response:
                            if response.status_code == 404:
                                return None
                            if response.status_code in {429, 503}:
                                self._retry_at = time.monotonic() + _retry_seconds(response.headers.get("Retry-After"))
                                raise UpstreamUnavailable
                            response.raise_for_status()
                            if response.headers.get("Content-Encoding", "identity").lower() != "identity":
                                raise UpstreamUnavailable
                            data = bytearray()
                            async for chunk in response.aiter_bytes(chunk_size=32 * 1024):
                                data.extend(chunk)
                                if len(data) > MAX_RESPONSE_BYTES:
                                    raise UpstreamUnavailable
                if json_response:
                    parsed = json.loads(data)
                    if not isinstance(parsed, dict):
                        raise UpstreamUnavailable
                    return parsed
                return bytes(data)
            except (httpx.HTTPError, TimeoutError, UnicodeError, ValueError) as error:
                raise UpstreamUnavailable from error

    async def cached(self, key, ttl, load):
        now = time.monotonic()
        entry = self._cache.get(key)
        if entry:
            self._cache.move_to_end(key)
            if now - entry[0] < ttl:
                return entry[1]

        task = self._pending.get(key)
        if task is None:
            if len(self._pending) >= MAX_OPEN_REQUESTS:
                if entry and now - entry[0] < STALE_TTL:
                    return entry[1]
                raise UpstreamUnavailable
            task = asyncio.create_task(self._load_cached(key, load, entry))
            task.add_done_callback(_consume_task_error)
            self._pending[key] = task
        return await asyncio.shield(task)

    async def _load_cached(self, key, load, stale):
        try:
            result = await load()
            self._cache[key] = time.monotonic(), result
            self._cache.move_to_end(key)
            if len(self._cache) > MAX_CACHE_ENTRIES:
                self._cache.popitem(last=False)
            return result
        except UpstreamUnavailable:
            if stale and time.monotonic() - stale[0] < STALE_TTL:
                return stale[1]
            raise
        finally:
            del self._pending[key]

    async def search(self, q, by, limit, offset):
        params = {"format": "json", "limit": limit, "offset": offset, "coverart": 1, "sort_order": "desc"}
        if q:
            params[by] = "^" + q if by == "title" else q
        books = await self._get("/api/feed/audiobooks/", params)
        if books is None:
            return {"items": [], "offset": offset, "next_offset": None}
        results = _records(books.get("books"))
        return {
            "items": [book for record in results if (book := _book(record))],
            "offset": offset,
            "next_offset": offset + limit if len(results) == limit else None,
        }

    async def manifest(self, book_id):
        response = await self._get("/api/feed/audiobooks/", {
            "format": "json", "id": book_id, "extended": 1, "coverart": 1,
        })
        if response is None:
            return None
        record = next((row for row in _records(response.get("books")) if str(row.get("id")) == book_id), None)
        if record is None or (book := _book(record)) is None:
            return None
        tracks = _api_tracks(record.get("sections"))
        if not tracks or len(tracks) < book["track_count"]:
            try:
                feed = await self._get(f"/rss/{book_id}", json_response=False)
                rss_tracks = _rss_tracks(feed) if feed else []
                if len(rss_tracks) > len(tracks):
                    tracks = _prefer_api_track_metadata(rss_tracks, tracks)
            except UpstreamUnavailable:
                if not tracks:
                    raise
        if not tracks or len(tracks) < book["track_count"]:
            raise UpstreamUnavailable
        if book["duration_seconds"] is None and all(track["duration_seconds"] for track in tracks):
            book["duration_seconds"] = sum(track["duration_seconds"] for track in tracks)
        return {**book, "track_count": len(tracks), "tracks": tracks}


def _consume_task_error(task):
    if not task.cancelled():
        task.exception()


def _retry_seconds(value):
    fallback = 30
    if not value:
        return fallback
    try:
        if value.isdecimal() and len(value) < 10:
            seconds = int(value)
        else:
            date = parsedate_to_datetime(value)
            seconds = (date - datetime.now(timezone.utc)).total_seconds()
        return min(3600, max(MIN_REQUEST_INTERVAL, seconds))
    except (ValueError, TypeError, OverflowError):
        return fallback


def _records(value):
    if isinstance(value, dict):
        value = value.values()
    elif not isinstance(value, list):
        return []
    return [row for row in value if isinstance(row, dict)]


def _plain(value, limit=200):
    if not isinstance(value, str) or not value.strip():
        return ""
    try:
        fragment = html.fragment_fromstring(value[: 8 * limit], create_parent=True)
    except (etree.LxmlError, ValueError):
        return ""
    for node in fragment.xpath(".//script | .//style"):
        node.drop_tree()
    return " ".join(fragment.text_content().split())[:limit]


def _number(value):
    text = str(value)
    return int(text) if re.fullmatch(r"[0-9]{1,9}", text) else None


def _seconds(value):
    direct = _number(value)
    if direct is not None:
        return direct or None
    if isinstance(value, str) and re.fullmatch(r"[0-9]{1,4}(?::[0-9]{1,2}){1,2}", value):
        seconds = 0
        for part in value.split(":"):
            seconds = seconds * 60 + int(part)
        return seconds or None
    return None


def _safe_parts(value):
    if not isinstance(value, str) or len(value) > 2048 or re.search(r"[\x00-\x20\x7f\\]", value):
        return None
    try:
        parts = urlsplit(value)
        if parts.scheme in {"http", "https"} and parts.username is None and parts.password is None and parts.port is None:
            return parts
    except ValueError:
        pass
    return None


def _archive_url(value, extensions):
    parts = _safe_parts(value)
    if not parts:
        return None
    host = parts.hostname or ""
    path = unquote(parts.path)
    if host in {"archive.org", "www.archive.org"} and path.startswith("/download/"):
        path = path[len("/download/"):]
    elif re.fullmatch(r"(?:ia|dn)\d+\.[a-z]{2}\.archive\.org", host):
        match = re.fullmatch(r"/(?:\d+/)?items/(.+)", path)
        if not match:
            return None
        path = match[1]
    else:
        return None
    segments = path.split("/")
    if (len(segments) < 2 or not re.fullmatch(r"[a-zA-Z0-9._-]{1,100}", segments[0])
            or any(segment in {"", ".", ".."} for segment in segments)
            or re.search(r"[\x00-\x1f\x7f\\%#?]", path)
            or not path.lower().endswith(extensions)):
        return None
    return f"https://archive.org/download/{quote(path, safe='/')}"


def _project_url(value, book_id):
    parts = _safe_parts(value)
    if parts and parts.hostname in {"librivox.org", "www.librivox.org"} and re.fullmatch(r"/[a-zA-Z0-9_-]+/?", parts.path):
        return urlunsplit(("https", "librivox.org", parts.path, "", ""))
    return f"{LIBRIVOX_URL}/api/feed/audiobooks/?id={book_id}"


def _book(record):
    book_id = str(record.get("id", ""))
    title = _plain(record.get("title"))
    if not re.fullmatch(r"[1-9][0-9]{0,8}", book_id) or not title:
        return None
    authors = [
        " ".join(filter(None, (_plain(person.get("first_name")), _plain(person.get("last_name")))))
        for person in _records(record.get("authors"))
    ]
    cover = next((
        image for field in ("coverart_thumbnail", "coverart_jpg")
        if (image := _archive_url(record.get(field), (".jpg", ".jpeg", ".png", ".webp")))
    ), None)
    return {
        "id": book_id,
        "title": title,
        "authors": list(dict.fromkeys(filter(None, authors))),
        "language": _plain(record.get("language"), 64),
        "description": _plain(record.get("description"), 1_200),
        "cover_url": cover,
        "source_url": _project_url(record.get("url_librivox"), book_id),
        "source": "LibriVox",
        "narration": "human",
        "rights": "public_domain_us",
        "rights_url": RIGHTS_URL,
        "duration_seconds": _seconds(record.get("totaltimesecs")) or _seconds(record.get("totaltime")),
        "track_count": _number(record.get("num_sections")) or 0,
    }


def _track(id_, title, duration, audio_url, readers=None):
    return {
        "id": id_,
        "title": title,
        "duration_seconds": _seconds(duration),
        "audio_url": audio_url,
        "readers": readers or [],
    }


def _ordered_tracks(tracks):
    result = []
    seen = set()
    for track in tracks:
        if track["audio_url"] in seen:
            continue
        index = len(result)
        result.append({**track, "index": index, "title": track["title"] or f"Track {index + 1}"})
        seen.add(track["audio_url"])
    return result


def _api_tracks(value):
    sections = _records(value)
    if len(sections) > MAX_TRACKS:
        raise UpstreamUnavailable
    ordered = sorted(enumerate(sections, 1), key=lambda item: _number(item[1].get("section_number")) or item[0])
    tracks = []
    for number, row in ordered:
        url = _archive_url(row.get("listen_url"), (".mp3", ".m4a", ".m4b"))
        if url:
            readers = [_plain(person.get("display_name")) for person in _records(row.get("readers"))]
            tracks.append(_track(str(row.get("id") or f"part-{number}"), _plain(row.get("title")), row.get("playtime"), url,
                                 list(dict.fromkeys(filter(None, readers)))))
    return _ordered_tracks(tracks)


def _rss_tracks(data):
    parser = etree.XMLParser(resolve_entities=False, no_network=True)
    try:
        feed = etree.fromstring(data, parser=parser)
    except etree.XMLSyntaxError as error:
        raise UpstreamUnavailable from error
    if feed.getroottree().docinfo.doctype:
        raise UpstreamUnavailable
    items = feed.findall("./channel/item")
    if len(items) > MAX_TRACKS:
        raise UpstreamUnavailable
    tracks = []
    for index, item in enumerate(items, 1):
        enclosure = item.find("enclosure")
        url = _archive_url(enclosure.get("url") if enclosure is not None else None, (".mp3", ".m4a", ".m4b"))
        if url:
            durations = item.xpath("./*[local-name()='duration']/text()")
            tracks.append(_track(f"rss-{index}", _plain(item.findtext("title")), durations[0] if durations else None, url))
    return _ordered_tracks(tracks)


def _prefer_api_track_metadata(rss_tracks, api_tracks):
    by_url = {track["audio_url"]: track for track in api_tracks}
    merged = []
    for track in rss_tracks:
        primary = by_url.get(track["audio_url"])
        if primary:
            track = {**primary, "duration_seconds": primary["duration_seconds"] or track["duration_seconds"]}
        merged.append({**track, "index": len(merged)})
    return merged


catalog = CatalogClient()


def _unavailable():
    return HTTPException(503, "The LibriVox catalog is temporarily unavailable. Try again shortly.", headers={"Retry-After": "30"})


@router.get("")
async def list_human_audiobooks(
    q: str = Query(default="", max_length=100),
    by: str = Query(default="title", pattern="^(title|author)$"),
    limit: int = Query(default=20, ge=1, le=40),
    offset: int = Query(default=0, ge=0, le=50_000),
):
    """Browse recordings or search by title prefix or exact author surname."""
    q = " ".join(q.split()).removeprefix("^").strip()
    try:
        return await catalog.cached(("search", q, by, limit, offset), SEARCH_TTL,
                                    lambda: catalog.search(q, by, limit, offset))
    except UpstreamUnavailable as error:
        raise _unavailable() from error


@router.get("/{book_id}")
async def human_audiobook_manifest(book_id: str):
    if not re.fullmatch(r"[1-9][0-9]{0,8}", book_id):
        raise HTTPException(404, "Audiobook not found.")
    try:
        manifest = await catalog.cached(("book", book_id), BOOK_TTL, lambda: catalog.manifest(book_id))
    except UpstreamUnavailable as error:
        raise _unavailable() from error
    if manifest is None:
        raise HTTPException(404, "Audiobook not found.")
    return manifest
