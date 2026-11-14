"""Local Project Gutenberg catalog search and on-demand mirror text retrieval."""

import asyncio
import csv
import gzip
import json
import logging
import os
import re
import unicodedata
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException
from lxml import etree


_LOG = logging.getLogger(__name__)
_SEED_PATH = Path(__file__).with_name("catalog_seed.json")
_MIRRORS = (
    "https://gutenberg.pglaf.org/cache/epub",
    "https://mirror.cs.odu.edu/gutenberg-epub",
)
_PAGE_SIZE = 24
_MAX_TEXT_BYTES = 20_000_000
_MAX_RDF_BYTES = 512_000
_START_MARKER = re.compile(r"^\s*\*{3}\s*START OF (?:THE|THIS) PROJECT GUTENBERG EBOOK[^\n]*\*{3}\s*$", re.I | re.M)
_END_MARKER = re.compile(r"^\s*\*{3}\s*END OF (?:THE|THIS) PROJECT GUTENBERG EBOOK[^\n]*\*{3}\s*$", re.I | re.M)


def _normalize(value: str) -> str:
    decomposed = unicodedata.normalize("NFKD", value.casefold())
    plain = "".join(char for char in decomposed if not unicodedata.combining(char))
    return " ".join(re.findall(r"[^\W_]+", plain))


@dataclass(frozen=True)
class _Entry:
    id: int
    title: str
    authors: tuple[str, ...]
    categories: tuple[str, ...]
    year: str = ""
    description: str = ""
    language: str = ""
    verified: bool = False

    def metadata(self, *, verified: bool = False) -> dict:
        return {
            "id": self.id,
            "title": self.title,
            "authors": list(self.authors),
            "categories": list(self.categories),
            "year": self.year,
            "description": self.description,
            "language": self.language,
            "cover": "",
            "source": f"https://www.gutenberg.org/ebooks/{self.id}",
            "public_domain": True if self.verified or verified else None,
        }


@dataclass(frozen=True)
class _SearchRecord:
    entry: _Entry
    title: str
    authors: str
    words: frozenset[str]

    @classmethod
    def from_entry(cls, entry: _Entry):
        title = _normalize(entry.title)
        authors = _normalize(" ".join(entry.authors))
        topics = _normalize(" ".join(entry.categories))
        return cls(entry, title, authors, frozenset(f"{title} {authors} {topics}".split()))

    def score(self, query: str, terms: frozenset[str]) -> int:
        if query == self.title:
            return 6
        if self.title.startswith(query):
            return 5
        if query in self.title:
            return 4
        if terms.issubset(self.title.split()):
            return 3
        if terms.issubset(f"{self.title} {self.authors}".split()):
            return 2
        return int(terms.issubset(self.words))


def _seed() -> dict[int, _Entry]:
    rows = json.loads(_SEED_PATH.read_text(encoding="utf-8"))
    return {
        row["id"]: _Entry(
            id=row["id"], title=row["title"], authors=tuple(row["authors"]),
            categories=tuple(row["categories"]), year=row.get("year", ""),
            description=row["description"], language="en", verified=True,
        )
        for row in rows
    }


_SEED = _seed()
_SEED_INDEX = {key: _SearchRecord.from_entry(value) for key, value in _SEED.items()}


def _author_name(value: str) -> str:
    value = re.sub(r"\s*\[[^]]+\]$", "", value.strip())
    value = re.sub(r",\s*(?:(?:ca\.\s*)?\d{1,4}\??\s*[-–]|active\s+).*$", "", value)
    family, comma, given = value.partition(", ")
    return f"{given} {family}" if comma else value


@lru_cache(maxsize=1)
def _catalog_index(path: Path, revision: tuple[int, int]) -> dict[int, _SearchRecord]:
    # Include mtime and size in the cache key so replacing the operator's snapshot refreshes search.
    open_csv = gzip.open if path.suffix.lower() == ".gz" else open
    records = {}
    with open_csv(path, "rt", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        required = {"Text#", "Type", "Title", "Language", "Authors", "Bookshelves"}
        if not required.issubset(reader.fieldnames or ()):
            raise ValueError("The Project Gutenberg catalog is missing expected CSV columns.")
        for row in reader:
            if row["Type"] != "Text" or not (row["Text#"] or "").isdecimal():
                continue
            book_id = int(row["Text#"])
            title = " ".join((row["Title"] or "").split())
            if not title or not 0 < book_id <= 999_999_999 or book_id in _SEED:
                continue
            authors = tuple(filter(None, (_author_name(name) for name in (row["Authors"] or "").split(";"))))
            categories = tuple(dict.fromkeys(
                shelf.strip().removeprefix("Category: ")
                for shelf in (row["Bookshelves"] or "").split(";") if shelf.strip()
            ))
            entry = _Entry(book_id, title, authors, categories, language=row["Language"] or "")
            records[book_id] = _SearchRecord.from_entry(entry)
    return records


def _operator_index() -> dict[int, _SearchRecord]:
    configured = os.getenv("GUTENBERG_CATALOG_PATH", "").strip()
    if not configured:
        return {}
    path = Path(configured).expanduser()
    try:
        stat = path.stat()
        return _catalog_index(path, (stat.st_mtime_ns, stat.st_size))
    except (OSError, UnicodeError, ValueError, EOFError, csv.Error) as error:
        _LOG.warning("Could not read the configured Project Gutenberg catalog: %s", error)
        return {}


def _search(query: str, page: int) -> tuple[list[dict], int | None]:
    start = max(0, page) * _PAGE_SIZE
    normalized = _normalize(query)
    if not normalized:
        entries = list(_SEED.values())
        return _catalog_page(entries, start, page)
    terms = frozenset(normalized.split())
    ranked = []
    for records in (_SEED_INDEX, _operator_index()):
        for record in records.values():
            score = record.score(normalized, terms)
            if score:
                ranked.append((score, record.entry))
    ranked.sort(key=lambda result: (-result[0], not result[1].verified, result[1].id))
    return _catalog_page([entry for _, entry in ranked], start, page)


def _catalog_page(entries: list[_Entry], start: int, page: int) -> tuple[list[dict], int | None]:
    end = start + _PAGE_SIZE
    return [entry.metadata() for entry in entries[start:end]], page + 1 if end < len(entries) else None


async def search_catalog(query: str, page: int = 0) -> tuple[list[dict], int | None]:
    return await asyncio.to_thread(_search, query, page)


def _mirrors() -> tuple[str, ...]:
    configured = os.getenv("GUTENBERG_MIRROR_URL", "").strip().rstrip("/")
    if not configured:
        return _MIRRORS
    try:
        url = urlsplit(configured)
        is_valid = (
            url.scheme == "https" and url.hostname and url.username is None
            and not url.query and not url.fragment
            and re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]+)?", url.netloc)
            and re.fullmatch(r"(?:/[A-Za-z0-9_.~-]+)*", url.path)
            and not any(part in {".", ".."} for part in url.path.split("/"))
            and (url.port is None or 1 <= url.port <= 65535)
        )
    except ValueError:
        is_valid = False
    if not is_valid:
        raise HTTPException(503, "The classics mirror is not configured with a valid HTTPS base URL.")
    return (configured,)


async def _read_asset(client: httpx.AsyncClient, url: str, limit: int) -> bytes:
    async with client.stream("GET", url) as response:
        response.raise_for_status()
        length = response.headers.get("content-length", "")
        if length.isdecimal() and int(length) > limit:
            raise HTTPException(413, "This catalog book exceeds the download size limit.")
        data = bytearray()
        async for chunk in response.aiter_bytes():
            if len(data) + len(chunk) > limit:
                raise HTTPException(413, "This catalog book exceeds the download size limit.")
            data.extend(chunk)
        return bytes(data)


def _read_rights(raw: bytes, book_id: int) -> bool:
    parser = etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False)
    root = etree.fromstring(raw, parser=parser)
    ebook = root.find("{http://www.gutenberg.org/2009/pgterms/}ebook")
    identity = f"ebooks/{book_id}"
    if ebook is None or ebook.get("{http://www.w3.org/1999/02/22-rdf-syntax-ns#}about") != identity:
        raise ValueError("The mirror record does not describe the requested ebook.")
    rights = ebook.findtext("{http://purl.org/dc/terms/}rights")
    return bool(rights and _normalize(rights) == "public domain in the usa")


def _read_text(raw: bytes) -> str:
    body = raw.decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
    start = _START_MARKER.search(body)
    end = _END_MARKER.search(body, start.end()) if start else None
    if not start or not end:
        raise ValueError("The mirror response has no complete Gutenberg ebook.")
    story = body[start.end():end.start()].strip()
    if len(story) < 25:
        raise ValueError("The mirror ebook did not contain readable text.")
    return "\n".join(
        " ".join(part.split())
        for part in re.split(r"\n[\t ]*\n+", story) if part.strip()
    )


async def load_catalog_book(id: int) -> tuple[dict, str]:
    if not 0 < id <= 999_999_999:
        raise HTTPException(404, "Catalog book not found.")
    entry = _SEED.get(id)
    if entry is None:
        record = (await asyncio.to_thread(_operator_index)).get(id)
        if record is None:
            raise HTTPException(404, "Catalog book not found.")
        entry = record.entry

    mirrors = _mirrors()
    not_found = 0
    try:
        async with asyncio.timeout(28):
            async with httpx.AsyncClient(
                timeout=httpx.Timeout(7, connect=4), follow_redirects=False,
                headers={"User-Agent": "TheTeller/1.0"},
            ) as client:
                for mirror in mirrors:
                    base = f"{mirror}/{id}/pg{id}"
                    try:
                        rights = await _read_asset(client, f"{base}.rdf", _MAX_RDF_BYTES)
                        if not _read_rights(rights, id):
                            raise HTTPException(404, "This edition is not marked public domain in the U.S.")
                        raw = await _read_asset(client, f"{base}.txt", _MAX_TEXT_BYTES)
                        story = await asyncio.to_thread(_read_text, raw)
                        return entry.metadata(verified=True), story
                    except httpx.HTTPStatusError as error:
                        if error.response.status_code in (404, 410):
                            not_found += 1
                    except (httpx.RequestError, ValueError, etree.XMLSyntaxError):
                        continue
    except TimeoutError:
        pass

    if not_found == len(mirrors):
        raise HTTPException(404, "A complete plain-text edition could not be found for this title.")
    raise HTTPException(502, "The classics mirror could not supply a complete book. Try again later.")
