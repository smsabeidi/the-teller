import asyncio
import codecs
import http.client
import io
import ipaddress
import json
import posixpath
import re
import socket
import ssl
import struct
import time
import zipfile
from pathlib import PurePath
from urllib.parse import parse_qsl, quote, unquote, urlencode, urljoin, urlsplit, urlunsplit

from fastapi import HTTPException
from lxml import etree, html


MAX_UPLOAD_BYTES = 100_000_000
MAX_ARCHIVE_BYTES = 256_000_000
MAX_ARCHIVE_ENTRIES = 10_000
MAX_MARKUP_BYTES = 16_000_000
MAX_REMOTE_BYTES = 12_000_000
MAX_TEXT_CHARS = 8_000_000
FETCH_SECONDS = 25
SOCKET_SECONDS = 7
MAX_REDIRECTS = 5

_ZIP_DIRECTORY = struct.Struct("<4s4H2IH")
_HTML_EXTENSIONS = (".html", ".htm", ".xhtml")
_WORD = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
_SSL_CONTEXT = ssl.create_default_context()
_BLOCK_TAGS = {
    "article", "blockquote", "dd", "div", "dl", "dt", "figcaption", "h1", "h2", "h3",
    "h4", "h5", "h6", "li", "main", "ol", "p", "pre", "section", "table", "td", "tr", "ul",
}
_SKIP_TAGS = {"aside", "button", "footer", "form", "nav", "noscript", "script", "style", "svg", "template"}
_TRANSITION_NETWORKS = tuple(ipaddress.ip_network(prefix) for prefix in ("64:ff9b::/96", "64:ff9b:1::/48", "2002::/16", "2001::/32"))
_AZURE_WIRESERVER = ipaddress.ip_address("168.63.129.16")


def _decode_text(raw: bytes, encoding: str | None = None) -> str:
    for marker, bom_encoding in (
        (codecs.BOM_UTF32_LE, "utf-32"), (codecs.BOM_UTF32_BE, "utf-32"),
        (codecs.BOM_UTF16_LE, "utf-16"), (codecs.BOM_UTF16_BE, "utf-16"),
    ):
        if raw.startswith(marker):
            return raw.decode(bom_encoding)
    for candidate in (encoding, "utf-8-sig", "cp1252"):
        if candidate:
            try:
                return raw.decode(candidate)
            except (LookupError, UnicodeError):
                continue
    raise HTTPException(400, "The file's text encoding could not be read. Save it as UTF-8 and try again.")


def _html_document(raw: bytes, encoding: str | None = None):
    # Give the HTML parser its original bytes when markup declares an encoding.
    if encoding or re.search(rb"charset\s*=|encoding\s*=", raw[:2048], re.I):
        try:
            return html.document_fromstring(raw, parser=html.HTMLParser(encoding=encoding, no_network=True))
        except LookupError:
            pass
    return html.document_fromstring(_decode_text(raw), parser=html.HTMLParser(no_network=True))


def _html_text(element) -> str:
    fragments = []

    def visit(node):
        tag = node.tag
        if not isinstance(tag, str) or tag in _SKIP_TAGS or node.get("hidden") is not None:
            return
        if node.get("aria-hidden") == "true" or node.get("role") in {"navigation", "complementary", "banner", "contentinfo"}:
            return
        if tag == "br":
            fragments.append("\n")
            return
        if tag == "hr":
            fragments.append("\n\n")
            return
        if tag in _BLOCK_TAGS:
            fragments.append("\n\n")
        if node.text:
            fragments.append(re.sub(r"\s+", " ", node.text) if tag != "pre" else node.text)
        for child in node:
            visit(child)
            if child.tail:
                fragments.append(re.sub(r"\s+", " ", child.tail))
        if tag in _BLOCK_TAGS:
            fragments.append("\n\n")

    visit(element)
    text = re.sub(r"[^\S\n]+", " ", "".join(fragments))
    text = re.sub(r" *\n *", "\n", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def _join_text(parts) -> str:
    sections = []
    length = 0
    for part in parts:
        part = part.strip()
        if part:
            length += len(part) + 2
            if length > MAX_TEXT_CHARS:
                raise HTTPException(413, "This document contains too much text. Try importing it in sections.")
            sections.append(part)
    return "\n\n".join(sections)


def _check_zip_directory(raw: bytes):
    # Bound central-directory allocation before ZipFile reads and expands its entries.
    minimum = max(0, len(raw) - 65_535 - _ZIP_DIRECTORY.size)
    # Use the first complete record ending at EOF, including archives with comments.
    cursor = len(raw)
    while (offset := raw.rfind(b"PK\x05\x06", minimum, cursor)) >= 0:
        cursor = offset
        if offset + _ZIP_DIRECTORY.size > len(raw):
            continue
        _, disk, directory_disk, disk_entries, entries, directory_size, _, comment = _ZIP_DIRECTORY.unpack_from(raw, offset)
        if offset + _ZIP_DIRECTORY.size + comment != len(raw):
            continue
        if disk or directory_disk or disk_entries != entries:
            raise HTTPException(400, "This split archive can't be imported. Save it again as a single file.")
        if entries > MAX_ARCHIVE_ENTRIES or directory_size > MAX_MARKUP_BYTES:
            raise HTTPException(413, "This archive contains too many files. Try importing it in sections.")
        return
    raise zipfile.BadZipFile("Missing central directory")


def _check_archive(archive: zipfile.ZipFile):
    entries = archive.infolist()
    if len(entries) > MAX_ARCHIVE_ENTRIES or sum(entry.file_size for entry in entries) > MAX_ARCHIVE_BYTES:
        raise HTTPException(413, "This document expands beyond the import limit. Try importing it in sections.")
    if any(entry.flag_bits & 1 for entry in entries):
        raise HTTPException(400, "This document is encrypted. Upload an unlocked copy.")
    if len({entry.filename for entry in entries}) != len(entries):
        raise HTTPException(400, "This document contains duplicate archive entries. Save a fresh copy and try again.")
    if any(entry.filename.lower().endswith((".xml", ".rels", ".opf", *_HTML_EXTENSIONS)) and entry.file_size > MAX_MARKUP_BYTES
           for entry in entries):
        raise HTTPException(413, "This document contains an oversized chapter or XML part. Try importing it in sections.")


def _xml_from_archive(archive: zipfile.ZipFile, path: str):
    parser = etree.XMLParser(resolve_entities=False, no_network=True, recover=False)
    return etree.fromstring(archive.read(path), parser=parser)


def _epub_path(base: str, reference: str) -> str:
    location = urlsplit(reference)
    path = unquote(location.path)
    if location.scheme or location.netloc or path.startswith("/") or "\\" in path or "\0" in path:
        raise ValueError("Invalid EPUB resource path")
    normalized = posixpath.normpath(posixpath.join(base, path))
    if normalized in {".", ".."} or normalized.startswith("../"):
        raise ValueError("Invalid EPUB resource path")
    return normalized


def _read_epub(archive: zipfile.ZipFile) -> str:
    container = _xml_from_archive(archive, "META-INF/container.xml")
    rootfiles = container.xpath("//*[local-name()='rootfile']/@full-path")
    if not rootfiles:
        raise ValueError("Missing EPUB package document")
    package_path = _epub_path("", rootfiles[0])
    package = _xml_from_archive(archive, package_path)
    manifest = {
        item.get("id"): item for item in package.xpath("./*[local-name()='manifest']/*[local-name()='item']")
    }
    spine = package.xpath("./*[local-name()='spine']/*[local-name()='itemref']")
    if not spine:
        raise ValueError("Missing EPUB reading order")

    def chapters():
        for reference in spine:
            if reference.get("linear") == "no":
                continue
            item = manifest[reference.get("idref")]
            if "nav" in item.get("properties", "").split():
                continue
            seen = set()
            while item.get("media-type") not in {"application/xhtml+xml", "text/html"}:
                fallback = item.get("fallback")
                if not fallback or fallback in seen:
                    raise ValueError("Missing EPUB text rendition")
                seen.add(fallback)
                item = manifest[fallback]
            chapter_path = _epub_path(posixpath.dirname(package_path), item.get("href", ""))
            chapter = _html_document(archive.read(chapter_path))
            yield _html_text(chapter.find("body") if chapter.find("body") is not None else chapter)

    return _join_text(chapters())


def _read_docx(raw: bytes) -> str:
    from docx import Document

    document = Document(io.BytesIO(raw))

    def paragraphs():
        for paragraph in document.element.body.iter(f"{_WORD}p"):
            fragments = []
            for run in paragraph.iter(f"{_WORD}t", f"{_WORD}tab", f"{_WORD}br", f"{_WORD}cr"):
                if run.tag == f"{_WORD}t":
                    fragments.append(run.text or "")
                else:
                    fragments.append("\t" if run.tag == f"{_WORD}tab" else "\n")
            yield "".join(fragments)

    return _join_text(paragraphs())


def _read_pdf(raw: bytes) -> str:
    from pypdf import PdfReader

    reader = PdfReader(io.BytesIO(raw))
    if reader.is_encrypted:
        raise HTTPException(400, "This PDF is encrypted. Upload an unlocked copy.")
    return _join_text(page.extract_text() or "" for page in reader.pages)


def extract_file(name: str, raw: bytes) -> str:
    if len(raw) > MAX_UPLOAD_BYTES:
        raise HTTPException(413, "Upload a file that is 100 MB or smaller.")
    if not raw:
        raise HTTPException(400, "The selected file is empty.")

    extension = PurePath(name).suffix.lower()
    try:
        if extension in {".txt", ".md"}:
            text = _decode_text(raw)
            if re.search(r"[\x00-\x08\x0b\x0e-\x1f]", text):
                raise HTTPException(400, "This file contains binary data. Upload a text document.")
        elif extension in _HTML_EXTENSIONS:
            page = _html_document(raw)
            body = page.find("body")
            text = _html_text(body if body is not None else page)
        elif extension == ".pdf":
            text = _read_pdf(raw)
        elif extension in {".epub", ".docx"}:
            if raw.startswith(bytes.fromhex("d0cf11e0a1b11ae1")):
                raise HTTPException(400, "This document is encrypted or in an older Word format. Save an unlocked DOCX copy.")
            _check_zip_directory(raw)
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                _check_archive(archive)
                text = _read_epub(archive) if extension == ".epub" else _read_docx(raw)
        else:
            raise HTTPException(400, "Upload an EPUB, PDF, DOCX, TXT, Markdown, or HTML file.")
    except HTTPException:
        raise
    except Exception as exc:
        from pypdf.errors import PdfReadError

        if not isinstance(exc, (PdfReadError, etree.LxmlError, zipfile.BadZipFile, EOFError,
                                KeyError, OSError, RuntimeError, TypeError, ValueError, IndexError)):
            raise
        raise HTTPException(400, f"This {extension[1:].upper()} file could not be read. Save a fresh, unlocked copy and try again.") from exc

    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        message = "This PDF contains no selectable text. Run OCR or upload a text version." if extension == ".pdf" else "The file contains no readable text. Upload another copy or paste the story."
        raise HTTPException(400, message)
    if len(text) > MAX_TEXT_CHARS:
        raise HTTPException(413, "This document contains too much text. Try importing it in sections.")
    return text


def _normalize_url(url: str) -> str:
    url = url.strip()
    if not url or len(url) > 4096 or re.search(r"[\s\x00-\x1f\x7f\\]", url):
        raise HTTPException(400, "Enter a valid public story link.")
    if not re.match(r"^[a-z][a-z0-9+.-]*://", url, re.I):
        url = f"https://{url}"
    try:
        parts = urlsplit(url)
        host = (parts.hostname or "").rstrip(".").encode("idna").decode("ascii").lower()
        port = parts.port
    except (UnicodeError, ValueError) as exc:
        raise HTTPException(400, "Enter a valid public story link.") from exc
    if parts.scheme not in {"http", "https"} or not host or not re.fullmatch(r"[a-z0-9.:-]+", host):
        raise HTTPException(400, "Enter a public HTTP or HTTPS story link.")
    default_port = 443 if parts.scheme == "https" else 80
    if parts.username is not None or parts.password is not None or port not in {None, default_port}:
        raise HTTPException(400, "Use a public story link without credentials or a custom port.")
    path = quote(parts.path or "/", safe="/%:@!$&'()*+,;=-._~")
    query = quote(parts.query, safe="/%?@!$&'()*+,;=:-._~")
    netloc = f"[{host}]" if ":" in host else host
    return urlunsplit((parts.scheme, netloc, path, query, ""))


def _is_public(address) -> bool:
    if isinstance(address, ipaddress.IPv6Address):
        if address.ipv4_mapped:
            return _is_public(address.ipv4_mapped)
        if address.is_site_local or any(address in network for network in _TRANSITION_NETWORKS):
            return False
    return address.is_global and not address.is_multicast and not address.is_reserved and address != _AZURE_WIRESERVER


def _public_addresses(host: str, port: int):
    try:
        address_info = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)
    except OSError as exc:
        raise HTTPException(400, "This story's hostname could not be resolved. Check the link.") from exc
    addresses = []
    for family, _, _, _, sockaddr in address_info:
        if family not in {socket.AF_INET, socket.AF_INET6} or not _is_public(ipaddress.ip_address(sockaddr[0])):
            raise HTTPException(400, "Only links on the public internet can be imported.")
        if (family, sockaddr) not in addresses:
            addresses.append((family, sockaddr))
    if not addresses:
        raise HTTPException(400, "No public address was found for this link.")
    return addresses


class _PinnedConnection(http.client.HTTPConnection):
    def __init__(self, host: str, port: int, tls: bool, addresses, deadline: float):
        super().__init__(host, port, timeout=SOCKET_SECONDS)
        self.tls = tls
        self.addresses = addresses
        self.deadline = deadline

    def connect(self):
        error = None
        for family, sockaddr in self.addresses:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Story fetch timed out")
            sock = socket.socket(family, socket.SOCK_STREAM, socket.IPPROTO_TCP)
            try:
                sock.settimeout(min(SOCKET_SECONDS, remaining))
                sock.connect(sockaddr)
                # TLS still uses the original hostname for SNI and certificate verification.
                if self.tls:
                    sock = _SSL_CONTEXT.wrap_socket(sock, server_hostname=self.host)
                self.sock = sock
                return
            except OSError as exc:
                sock.close()
                error = exc
        raise OSError("No public story address could be reached") from error


def _story_url(url: str) -> str:
    parts = urlsplit(url)
    if parts.hostname in {"archiveofourown.org", "www.archiveofourown.org"} and re.fullmatch(r"/works/\d+/?", parts.path):
        parameters = parse_qsl(parts.query, keep_blank_values=True)
        if not any(key == "view_full_work" for key, _ in parameters):
            parameters.append(("view_full_work", "true"))
            return urlunsplit(parts._replace(query=urlencode(parameters)))
    return url


def _fetch_public(url: str):
    deadline = time.monotonic() + FETCH_SECONDS
    for _ in range(MAX_REDIRECTS + 1):
        parts = urlsplit(url)
        tls = parts.scheme == "https"
        port = 443 if tls else 80
        addresses = _public_addresses(parts.hostname, port)
        target = urlunsplit(("", "", parts.path, parts.query, ""))
        connection = _PinnedConnection(parts.hostname, port, tls, addresses, deadline)
        try:
            connection.request("GET", target, headers={
                "User-Agent": "VoiceEmo Studio/1.0",
                "Accept": "text/html, application/xhtml+xml, text/plain, application/json",
                "Accept-Encoding": "identity",
            })
            with connection.getresponse() as response:
                if response.status in {301, 302, 303, 307, 308}:
                    location = response.getheader("Location")
                    if not location:
                        raise HTTPException(400, "The story site returned a redirect without a destination.")
                    url = _story_url(_normalize_url(urljoin(url, location)))
                    if tls and urlsplit(url).scheme != "https":
                        raise HTTPException(400, "This story redirects to an insecure link. Use its direct HTTPS link.")
                    continue
                if response.status in {401, 403, 429, 451} or response.getheader("CF-Mitigated") == "challenge":
                    raise HTTPException(400, "The story site restricted access. Paste the story text or upload a copy instead.")
                if response.status != 200:
                    raise HTTPException(400, f"The story site returned HTTP {response.status}. Check the link or paste the text.")
                content_type = response.headers.get_content_type()
                if response.getheader("Content-Type") and content_type not in {"text/html", "application/xhtml+xml", "text/plain", "application/json"}:
                    raise HTTPException(400, "This link does not point to a readable story page. Download the book and upload it instead.")
                if response.getheader("Content-Encoding", "identity").lower() != "identity":
                    raise HTTPException(400, "This story site returned an unsupported encoding. Paste or upload the story instead.")
                length = response.getheader("Content-Length", "")
                if length.isascii() and length.isdecimal() and (len(length) > 12 or int(length) > MAX_REMOTE_BYTES):
                    raise HTTPException(413, "This story page is too large to import by link. Try uploading the book instead.")
                data = bytearray()
                while True:
                    if time.monotonic() > deadline:
                        raise TimeoutError("Story fetch timed out")
                    chunk = response.read1(min(64 * 1024, MAX_REMOTE_BYTES + 1 - len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                    if len(data) > MAX_REMOTE_BYTES:
                        raise HTTPException(413, "This story page is too large to import by link. Try uploading the book instead.")
                return url, content_type, response.headers.get_content_charset(), bytes(data)
        finally:
            connection.close()
    raise HTTPException(400, "This link redirects too many times. Try the direct story URL.")


def _read_story_page(url: str, content_type: str, encoding: str | None, data: bytes) -> tuple[str, str, str]:
    host = urlsplit(url).hostname
    if content_type == "text/plain" and not data.lstrip().startswith(b"<"):
        title = unquote(posixpath.basename(urlsplit(url).path)) or host
        return title, _decode_text(data, encoding), ""
    if content_type == "application/json" and (host == "reddit.com" or host.endswith(".reddit.com")):
        post = json.loads(data)[0]["data"]["children"][0]["data"]
        return post.get("title") or "Reddit story", post.get("selftext", ""), post.get("author") or ""

    page = _html_document(data, encoding)
    title = next((value.strip() for value in page.xpath(
        "//meta[@property='og:title']/@content | //meta[@name='twitter:title']/@content"
    ) if value.strip()), "")
    if not title:
        title = " ".join(page.xpath("//title/text()")[:1]).strip() or url
    author = next((value.strip() for value in page.xpath(
        "//meta[@name='author']/@content | //*[@rel='author']/text()"
    ) if value.strip()), "")

    if host in {"archiveofourown.org", "www.archiveofourown.org"}:
        # AO3 chapter content excludes the story metadata, notes, kudos and comments.
        nodes = page.xpath(
            "//*[@id='chapters']//*[@role='article'][contains(concat(' ', normalize-space(@class), ' '), ' userstuff ')]"
        )
        return title, _join_text(_html_text(node) for node in nodes), author
    if host == "reddit.com" or host.endswith(".reddit.com"):
        nodes = page.xpath("//shreddit-post//*[@slot='text-body'] | //div[contains(concat(' ', normalize-space(@class), ' '), ' usertext-body ')]")
        return title, _join_text(_html_text(node) for node in nodes[:1]), author
    if host in {"wattpad.com", "www.wattpad.com"}:
        nodes = page.xpath("//*[@data-testid='story-part-text'] | //p[@data-p-id] | //pre[@data-p-id]")
        return title, _join_text(_html_text(node) for node in nodes
                                 if not any(parent in nodes for parent in node.iterancestors())), author

    for selector in (
        "//*[contains(concat(' ', normalize-space(@class), ' '), ' available-content ')]",
        "//article",
        "//main | //*[@role='main']",
        "//body",
    ):
        candidate = max((_html_text(node) for node in page.xpath(selector)), key=len, default="")
        if len(candidate) >= 25:
            return title, candidate, author
    return title, "", author


async def fetch_url(url: str) -> tuple[str, str, str]:
    try:
        normalized = _story_url(_normalize_url(url))
        page = await asyncio.wait_for(asyncio.to_thread(_fetch_public, normalized), timeout=FETCH_SECONDS + 1)
        title, text, author = await asyncio.to_thread(_read_story_page, *page)
    except TimeoutError as exc:
        raise HTTPException(408, "The story site took too long to respond. Try again or paste the text.") from exc
    except (OSError, http.client.HTTPException) as exc:
        raise HTTPException(400, "The story site could not be reached. Check the link or paste the text.") from exc
    except (etree.LxmlError, KeyError, IndexError, TypeError, ValueError) as exc:
        raise HTTPException(400, "This page could not be read as a story. Paste the text or upload a file.") from exc
    if not text.strip():
        raise HTTPException(400, "No public story text was found at this link. Paste the text or upload a file.")
    if len(text) > MAX_TEXT_CHARS:
        raise HTTPException(413, "This story contains too much text. Try importing it in sections.")
    return title[:240], text.strip(), author[:160]
