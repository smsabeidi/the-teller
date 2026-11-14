"""
VoiceEmo Studio — an Audora-style AI audiobook studio.

Flow (modelled on audora.art):
  1. Bring a story  -> paste a link (AO3, Wattpad, Reddit, Substack, any page),
                       upload epub/pdf/docx/txt, or paste text
  2. We cast it     -> narration + every speaking character gets a distinct voice
                       and a per-line emotion
  3. Press play     -> free preview of the opening, tap any line to listen from there

Run:
  pip install -r requirements.txt
  cp .env.example .env      # add keys (optional - works without them in demo mode)
  uvicorn server:app --reload --port 8000
  open http://localhost:8000
"""
import asyncio
import hashlib
import hmac
import json
import logging
import os
import re
import shutil
import uuid
import zipfile
from pathlib import Path

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.datastructures import Headers

from account import attach_book, browser_owner, owned_catalog_book, personal_mode, require_book, same_origin, set_book_remover
from account import router as account_router
from book_catalog import load_catalog_book, search_catalog
from human_audio import router as human_audio_router
from story_import import MAX_UPLOAD_BYTES, extract_file, fetch_url

load_dotenv()
LOGGER = logging.getLogger(__name__)

ELEVENLABS_API_KEY = os.getenv("ELEVENLABS_API_KEY", "").strip()
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "").strip()
PREVIEW_LINES = max(1, int(os.getenv("PREVIEW_LINES", "12")) or 12)
MAX_CHARS = int(os.getenv("MAX_CHARS", "1000000"))
MAX_CATALOG_CHARS = int(os.getenv("MAX_CATALOG_CHARS", "4000000"))

BASE = Path(__file__).parent
DATA = Path(os.getenv("VOICEEMO_DATA_DIR") or BASE / "data")
CACHE = DATA / "audio"
BOOKS = DATA / "books"
for d in (CACHE, BOOKS):
    d.mkdir(parents=True, exist_ok=True)

# ----------------------------------------------------------------------------
# Voices
# ----------------------------------------------------------------------------
EL_VOICES = {  # ElevenLabs premade voices
    "narrator_f": ("21m00Tcm4TlvDq8ikWAM", "Rachel", "female"),
    "narrator_m": ("pNInz6obpgDQGcFmaJgB", "Adam", "male"),
    "m1": ("TxGEqnHWrfWFTfGW9XjX", "Josh", "male"),
    "m2": ("ErXwobaYiN019PkySvjV", "Antoni", "male"),
    "m3": ("yoZ06aMxZJJ28mfd3POQ", "Sam", "male"),
    "m4": ("2EiwWnXFnvU5JabPnv8n", "Clyde", "male"),
    "m5": ("29vD33N1CtxCmqQRPOHJ", "Drew", "male"),
    "f1": ("EXAVITQu4vr4xnSDxMaL", "Bella", "female"),
    "f2": ("MF3mGyEYCl7XYWbV9V6O", "Elli", "female"),
    "f3": ("AZnzlk1XvdvUeBnXmlld", "Domi", "female"),
    "f4": ("ThT5KcBeYPX3keUQqHPh", "Dorothy", "female"),
}
OA_VOICES = {  # OpenAI gpt-4o-mini-tts voices
    "narrator_f": "sage", "narrator_m": "fable",
    "m1": "onyx", "m2": "echo", "m3": "ash", "m4": "verse", "m5": "ballad",
    "f1": "nova", "f2": "shimmer", "f3": "coral", "f4": "alloy",
}
EMOTIONS = ["neutral", "happy", "sad", "angry", "scared", "excited",
            "whisper", "surprised", "tender", "sarcastic"]
OA_STYLE = {
    "neutral": "Read naturally, like a skilled audiobook performer.",
    "happy": "Warm and joyful, with a smile in the voice.",
    "sad": "Quiet, heavy and sorrowful.",
    "angry": "Sharp, tense and angry.",
    "scared": "Breathless, nervous and frightened.",
    "excited": "Fast, bright and excited.",
    "whisper": "A hushed whisper.",
    "surprised": "Startled and astonished.",
    "tender": "Soft, gentle and affectionate.",
    "sarcastic": "Dry and sarcastic.",
}


def provider() -> str:
    if ELEVENLABS_API_KEY:
        return "elevenlabs"
    if OPENAI_API_KEY:
        return "openai"
    return "browser"  # demo mode: frontend uses the Web Speech API


# ----------------------------------------------------------------------------
# Casting: split text into performed lines
# ----------------------------------------------------------------------------
SPEECH_VERBS = (r"said|says|asked|asks|replied|whispered|shouted|yelled|muttered|cried|"
                r"called|answered|snapped|hissed|growled|murmured|laughed|sighed|gasped|"
                r"screamed|exclaimed|added|continued|demanded|pleaded|told|began|breathed|"
                r"remarked|observed|returned|rejoined|interrupted|responded|inquired|enquired|"
                r"retorted|repeated|insisted|urged|protested|groaned|whimpered|stammered|"
                r"faltered|declared|explained|suggested|thundered|roared|went on")
VERB_EMOTION = {"whisper": "whisper", "murmur": "whisper", "breath": "whisper",
                "shout": "angry", "yell": "angry", "snap": "angry", "hiss": "angry",
                "growl": "angry", "roar": "angry", "thunder": "angry", "retort": "angry",
                "protest": "angry", "scream": "scared", "stammer": "scared", "falter": "scared",
                "whimper": "scared", "gasp": "surprised", "exclaim": "excited",
                "interrupt": "excited", "laugh": "happy", "sigh": "sad", "groan": "sad",
                "plead": "sad", "cried": "sad"}
STOP = set(("He She They I We You It The A An But And Then His Her Their My Mr Mrs Ms Dr "
            "This That What When Where Why How Yes No Oh Ah Well Now There Here So If As At In "
            "On Of For To With Not All One Our Your Its Who Whom Which After Before Again Still "
            "Just Even Only Perhaps Indeed Come Good Very Sir Madam").split())
TITLES = set(("mr mrs ms miss dr doctor lord lady sir madam madame captain colonel major professor "
              "inspector count countess father mother aunt uncle king queen prince princess").split())
FEMALE_TITLES = set("mrs ms miss lady madam madame countess mother aunt queen princess".split())
MALE_TITLES = set("mr sir lord count father uncle king prince captain colonel major".split())
_T = (r"(?:Mr|Mrs|Ms|Miss|Dr|Doctor|Lord|Lady|Sir|Madam|Madame|Captain|Colonel|Major|Professor|"
      r"Inspector|Count|Countess|Father|Mother|Aunt|Uncle|King|Queen|Prince|Princess)\.?")
NAME = rf"(?:the\s+)?(?:{_T}\s+)?[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?"
WHO = rf"(?:{NAME}|[Hh]e|[Ss]he|I)"
TAG_AFTER = re.compile(rf"^\s*[,!?.\u2014-]*\s*(?:({SPEECH_VERBS})\s+({WHO})\b|({WHO})\s+(?:[a-z]+ly\s+)?({SPEECH_VERBS})\b)")
TAG_BEFORE = re.compile(rf"\b({WHO})\s+(?:[a-z]+ly\s+)?({SPEECH_VERBS})\b[\s,:\u2014-]{{0,40}}$")
LEAD_NAME = re.compile(NAME)


def guess_emotion(text: str, verb: str = "") -> str:
    for k, v in VERB_EMOTION.items():
        if k in (verb or "").lower():
            return v
    if text.rstrip().endswith("!"):
        return "excited"
    if "..." in text or "\u2026" in text:
        return "scared" if "?" in text else "sad"
    return "neutral"


def detect_quote(text: str):
    dbl = text.count('"') + text.count("\u201c")
    sgl = text.count("\u2018")
    if sgl and sgl > dbl:   # British single-quote style: 'I don't know,' said he.
        return re.compile(r"\u2018(.+?)\u2019(?![a-z])")
    return re.compile(r"[\"\u201c]([^\"\u201d]+)[\"\u201d]")


def canon(raw: str):
    parts = raw.replace(".", "").split()
    while len(parts) > 1 and (parts[0] in STOP or parts[0].lower() == "the") and parts[0].lower() not in TITLES:
        parts.pop(0)
    if parts and parts[0].lower() == "the":
        parts.pop(0)
    if not parts or (parts[0] in STOP and parts[0].lower() not in TITLES):
        return None, None, None
    title = parts[0].lower() if len(parts) > 1 and parts[0].lower() in TITLES else ""
    key = ("f:" if title in FEMALE_TITLES else "") + parts[-1]
    disp = (parts[0] + ". " + " ".join(parts[1:])) if title in ("mr", "mrs", "ms", "dr") else " ".join(parts)
    g = "female" if title in FEMALE_TITLES else "male" if title in MALE_TITLES else None
    return key, disp, g


def cast_classic(text: str) -> tuple[list[dict], dict]:
    """Rule-based casting tuned for classic fiction: titles, 'said he', first-person narrators,
    single-quote dialogue and untagged back-and-forth."""
    quote = detect_quote(text)
    first_person = len(re.findall(r"\bI (?:said|asked|answered|replied|cried|remarked)\b", text)) >= 1
    lines, recent, display, genders = [], [], {}, {}
    last = None

    def gender_guess(name):
        first = name.split()[0].lower().rstrip(".")
        g = COMMON_GENDER.get(first) or COMMON_GENDER.get(name.split()[-1].lower())
        if g:
            return g
        near = " ".join(re.findall(rf"{re.escape(name.split()[-1])}[^.]{{0,80}}", text)[:15])
        return "female" if len(FEMALE_HINT.findall(near)) > len(MALE_HINT.findall(near)) else "male"

    mentions: list[str] = []

    def note_mentions(t):
        for m in re.finditer(NAME, t):
            key, disp, g = canon(m.group(0))
            if key and len(disp) > 2:
                nm = display.setdefault(key, disp)
                if g and nm not in genders:
                    genders[nm] = g
                mentions.append(nm)
        del mentions[:-12]

    def mentioned(g):
        for nm in reversed(mentions):
            if nm != last and nm != "Narrator" and (genders.get(nm) or gender_guess(nm)) == g:
                return nm
        return None

    def by_pronoun(g):
        cands = [s for s in reversed(recent[-6:]) if s != "Narrator" and genders.get(s) == g]
        for c in cands:
            if c != last:
                return c
        return cands[0] if cands else None

    for para in (p.strip() for p in text.split("\n")):
        if not para:
            continue
        qs = list(quote.finditer(para))
        if not qs:
            lines.append({"speaker": "Narrator", "text": para, "emotion": "neutral"})
            note_mentions(para)
            continue
        pos = 0
        for i, q in enumerate(qs):
            raw = verb = None
            before_quote = para[pos:q.start()]
            following = qs[i + 1].start() if i + 1 < len(qs) else len(para)
            after_quote = para[q.end():following]
            note_mentions(before_quote)
            before_tag = TAG_BEFORE.search(before_quote[-100:])
            after_tag = TAG_AFTER.match(after_quote[:80])
            if before_tag:
                raw, verb = before_tag.groups()
            elif after_tag:
                said, inverted_name, direct_name, direct_verb = after_tag.groups()
                raw, verb = (inverted_name, said) if said else (direct_name, direct_verb)
            elif i == 0 and (m := LEAD_NAME.match(before_quote.strip())):
                raw = m.group(0)

            speaker = None
            if raw:
                name = raw.strip()
                if name == "I":
                    speaker = "Narrator"
                elif name.lower() in ("he", "she"):
                    gender = "male" if name.lower() == "he" else "female"
                    speaker = by_pronoun(gender) or mentioned(gender)
                else:
                    key, label, gender = canon(name)
                    if key:
                        speaker = display.setdefault(key, label)
                        if gender:
                            genders.setdefault(speaker, gender)
            if not speaker:
                if len(recent) >= 2:
                    speaker = recent[-2] if recent[-1] == last else recent[-1]
                elif first_person and last and last != "Narrator":
                    speaker = "Narrator"
                elif recent:
                    speaker = recent[-1]
                speaker = speaker or mentioned("male") or mentioned("female") or "Stranger"
            if speaker != "Narrator" and speaker not in genders:
                genders[speaker] = gender_guess(speaker)

            narration = before_quote.strip(" ,")
            if narration:
                lines.append({"speaker": "Narrator", "text": narration, "emotion": "neutral"})
            dialogue = q.group(1).strip()
            if dialogue:
                lines.append({"speaker": speaker, "text": dialogue,
                              "emotion": guess_emotion(dialogue, verb), "d": True})
            pos = q.end()
            if not recent or recent[-1] != speaker:
                recent.append(speaker)
            last = speaker
        after = para[pos:].strip(" ,")
        if after:
            lines.append({"speaker": "Narrator", "text": after, "emotion": "neutral"})
    return lines, {n: {"gender": g} for n, g in genders.items()}


COMMON_GENDER = {n: "female" for n in "jenny sophie emma olivia ava mia lily grace anna sarah mary emily alice lucy kate chloe ella zoe hannah rose clara jane elizabeth amy laura rachel sophia isabella abigail ruby irene mina lucy".split()}
COMMON_GENDER.update({n: "male" for n in "tyler noah liam james jack john david michael tom harry ben sam alex daniel matt luke jake ethan adam peter mark paul george henry oliver william jonathan sherlock watson".split()})
FEMALE_HINT = re.compile(r"\b(she|her|hers|herself)\b", re.I)
MALE_HINT = re.compile(r"\b(he|him|his|himself)\b", re.I)


def assign_voices(lines: list[dict], text: str, genders: dict) -> dict:
    counts: dict[str, int] = {}
    for l in lines:
        counts[l["speaker"]] = counts.get(l["speaker"], 0) + 1
    narrator_gender = "female"
    cast = {"Narrator": {"voice": "narrator_f", "gender": narrator_gender, "lines": counts.pop("Narrator", 0)}}
    available = [voice for voice in EL_VOICES if voice != "narrator_f"]
    for index, (name, n) in enumerate(sorted(counts.items(), key=lambda item: -item[1])):
        gender = (genders.get(name) or {}).get("gender") or COMMON_GENDER.get(name.lower())
        if gender not in ("male", "female"):
            near = " ".join(re.findall(rf"{re.escape(name)}[^.]{{0,80}}", text)[:20])
            gender = "female" if len(FEMALE_HINT.findall(near)) > len(MALE_HINT.findall(near)) else "male"
        preferred = next((voice for voice in available if EL_VOICES[voice][2] == gender), None)
        voice = preferred or (available[0] if available else list(EL_VOICES)[1 + (index % (len(EL_VOICES) - 1))])
        if voice in available:
            available.remove(voice)
        cast[name] = {"voice": voice, "gender": gender, "lines": n}
    return cast


# ----------------------------------------------------------------------------
# Storage
# ----------------------------------------------------------------------------
_BOOK_CACHE: dict[str, dict] = {}


def save_book(b: dict):
    path = BOOKS / f"{b['id']}.json"
    temp = path.with_name(f"{b['id']}.{uuid.uuid4().hex}.tmp")
    try:
        temp.write_text(json.dumps(b), encoding="utf-8")
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)
    if len(_BOOK_CACHE) >= 50 and b["id"] not in _BOOK_CACHE:
        _BOOK_CACHE.pop(next(iter(_BOOK_CACHE)))
    _BOOK_CACHE[b["id"]] = b


def load_book(book_id: str) -> dict:
    if not re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", book_id):
        raise HTTPException(404, "Book not found")
    if book_id in _BOOK_CACHE:
        return _BOOK_CACHE[book_id]
    p = BOOKS / f"{book_id}.json"
    if not p.exists():
        raise HTTPException(404, "Book not found")
    b = json.loads(p.read_text())
    if len(_BOOK_CACHE) > 50:
        _BOOK_CACHE.pop(next(iter(_BOOK_CACHE)))
    _BOOK_CACHE[book_id] = b
    return b


# ----------------------------------------------------------------------------
# TTS
# ----------------------------------------------------------------------------
async def tts(book_id: str, text: str, voice_slot: str, emotion: str) -> bytes:
    prov = provider()
    model = os.getenv("ELEVENLABS_MODEL", "eleven_v3") if prov == "elevenlabs" else "gpt-4o-mini-tts"
    key = hashlib.sha256(f"{prov}|{model}|{voice_slot}|{emotion}|{text}".encode()).hexdigest()
    directory = CACHE / book_id
    directory.mkdir(exist_ok=True)
    path = directory / f"{key}.mp3"
    if path.exists():
        return path.read_bytes()

    async with httpx.AsyncClient(timeout=60) as c:
        if prov == "elevenlabs":
            vid = EL_VOICES.get(voice_slot, EL_VOICES["narrator_f"])[0]
            # eleven_v3 understands inline audio tags such as [whispers] / [excited]
            tag = "" if emotion == "neutral" else f"[{'whispers' if emotion == 'whisper' else emotion}] "
            r = await c.post(f"https://api.elevenlabs.io/v1/text-to-speech/{vid}?output_format=mp3_44100_128",
                             headers={"xi-api-key": ELEVENLABS_API_KEY},
                             json={"text": tag + text, "model_id": model})
        else:
            r = await c.post("https://api.openai.com/v1/audio/speech",
                             headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
                             json={"model": model, "voice": OA_VOICES.get(voice_slot, "sage"),
                                   "input": text, "instructions": OA_STYLE.get(emotion, OA_STYLE["neutral"]),
                                   "response_format": "mp3"})
    if r.status_code != 200:
        LOGGER.warning("%s returned HTTP %s for speech generation", prov, r.status_code)
        raise HTTPException(502, "The voice provider could not generate this line. Try again.")
    if directory.is_dir():
        path.write_bytes(r.content)
    return r.content


# ----------------------------------------------------------------------------
# API
# ----------------------------------------------------------------------------
app = FastAPI(title="VoiceEmo Studio")
app.include_router(account_router)
app.include_router(human_audio_router)

SITE_PASSWORD = os.getenv("SITE_PASSWORD", "").strip()
ACCESS_KEY = os.getenv("TELLER_ACCESS_KEY", "").strip()
if personal_mode() and not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", ACCESS_KEY):
    raise RuntimeError("Personal mode requires TELLER_ACCESS_KEY (32–128 URL-safe characters).")
MAX_EXPORT_CHARS = int(os.getenv("MAX_EXPORT_CHARS", str(MAX_CHARS)))
IMPORTS_PER_HOUR = int(os.getenv("IMPORTS_PER_HOUR", "20"))
_hits: dict[str, list[float]] = {}


def rate_ok(ip: str, limit: int) -> bool:
    import time
    now = time.time()
    h = [t for t in _hits.get(ip, []) if now - t < 3600]
    if len(h) >= limit:
        _hits[ip] = h
        return False
    h.append(now)
    _hits[ip] = h
    return True


class ImportBodyLimit:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "POST" or scope["path"] != "/api/import":
            await self.app(scope, receive, send)
            return

        limit = MAX_UPLOAD_BYTES + 64 * 1024
        size = Headers(scope=scope).get("content-length", "")
        if size.isdecimal() and (len(size) > 12 or int(size) > limit):
            response = JSONResponse({"detail": "Choose a file up to 100 MB."}, status_code=413)
            await response(scope, receive, send)
            return

        received = 0

        async def bounded_receive():
            nonlocal received
            message = await receive()
            received += len(message.get("body", b""))
            if received > limit:
                raise HTTPException(413, "Choose a file up to 100 MB.")
            return message

        await self.app(scope, bounded_receive, send)


app.add_middleware(ImportBodyLimit)


@app.middleware("http")
async def guard(request, call_next):
    import base64
    if personal_mode() and request.url.path != "/api/health":
        auth = request.headers.get("authorization", "")
        kind, _, candidate = auth.partition(" ")
        if kind.lower() != "bearer" or not hmac.compare_digest(candidate.encode(), ACCESS_KEY.encode()):
            return JSONResponse({"detail": "Enter your personal server key in Settings."}, status_code=401,
                                headers={"Cache-Control": "no-store", "WWW-Authenticate": "Bearer"})
        request.state.teller_personal = True
    elif SITE_PASSWORD and request.url.path not in ("/api/health", "/api/stripe/webhook"):
        auth = request.headers.get("authorization", "")
        ok = False
        if auth.startswith("Basic "):
            try:
                pw = base64.b64decode(auth[6:]).decode().split(":", 1)[-1]
                ok = hmac.compare_digest(pw.encode(), SITE_PASSWORD.encode())
            except Exception:
                pass
        if not ok:
            return Response("Password required", status_code=401,
                            headers={"WWW-Authenticate": 'Basic realm="VoiceEmo"'})
    if request.method == "POST" and (
        request.url.path in ("/api/import", "/api/library/open") or request.url.path.startswith("/api/catalog/")
    ):
        ip = request.client.host if request.client else "unknown"
        if not rate_ok(ip, IMPORTS_PER_HOUR):
            return JSONResponse({"detail": "Too many stories this hour. Try again later."}, status_code=429)
    response = await call_next(request)
    if request.url.path.startswith(("/api/books/", "/api/my/", "/api/account", "/api/auth/", "/api/import", "/api/catalog/")):
        response.headers["Cache-Control"] = "private, no-store"
    return response


@app.get("/api/health")
def health():
    return {"ok": True, "provider": provider(), "llm_casting": bool(OPENAI_API_KEY)}


@app.get("/api/voices")
def voices():
    if provider() == "openai":
        names = {slot: voice.title() for slot, voice in OA_VOICES.items()}
    elif provider() == "elevenlabs":
        names = {slot: entry[1] for slot, entry in EL_VOICES.items()}
    else:
        names = {slot: f"Voice {index}" for index, slot in enumerate(EL_VOICES, 1)}
    return {slot: {"name": name, "gender": EL_VOICES[slot][2]} for slot, name in names.items()}


@app.post("/api/import")
async def import_story(
    request: Request, response: Response, url: str = Form(""), text: str = Form(""),
    file: UploadFile | None = File(None),
):
    same_origin(request)
    title = "Untitled story"
    author = ""
    if file is not None and file.filename:
        raw = await file.read(MAX_UPLOAD_BYTES + 1)
        body = await asyncio.to_thread(extract_file, file.filename, raw)
        title = Path(file.filename).stem.replace("_", " ").strip()[:120] or title
    elif url.strip():
        title, body, author = await fetch_url(url.strip())
    elif text.strip():
        body = text
        title = text.strip().splitlines()[0][:70]
    else:
        raise HTTPException(400, "Paste a story link, upload a file, or paste some text.")

    body = re.sub(r"\n{3,}", "\n\n", body.replace("\r\n", "\n").replace("\r", "\n")).strip()
    if len(body) < 25:
        raise HTTPException(400, "Add at least 25 characters of readable story text.")
    if len(body) > MAX_CHARS:
        raise HTTPException(413, f"This story has {len(body):,} characters. Import up to {MAX_CHARS:,} at a time.")

    lines, genders = await asyncio.to_thread(cast_classic, body)
    lines = split_long_lines(lines)
    if not lines:
        raise HTTPException(400, "No readable story text was found.")
    unlocked = bool(getattr(request.state, "teller_personal", False))
    book = {"id": str(uuid.uuid4()), "title": title, "lines": lines,
            "cast": assign_voices(lines, body, genders), "words": len(body.split()), "author": author,
            "private": unlocked}
    owner = browser_owner(request, response)
    save_book(book)
    try:
        attach_book(book["id"], owner, title, author, unlocked=unlocked)
    except Exception:
        remove_book(book["id"])
        raise
    return summary(book, unlocked=unlocked)


def split_long_lines(lines: list[dict]) -> list[dict]:
    result = []
    for line in lines:
        text = line["text"]
        while len(text) > 480:
            cutoff = max(text.rfind(mark, 200, 480) + len(mark) for mark in (". ", "! ", "? "))
            if cutoff < 200:
                cutoff = text.rfind(" ", 0, 480)
            if cutoff < 1:
                cutoff = 480
            result.append(dict(line, text=text[:cutoff].strip()))
            text = text[cutoff:].lstrip()
        if text:
            result.append(dict(line, text=text))
    return result


def summary(book: dict, unlocked: bool = True) -> dict:
    total = len(book["lines"])
    limit = total if unlocked else min(PREVIEW_LINES, total)
    return {"id": book["id"], "title": book["title"], "words": book["words"],
            "author": book.get("author", ""), "cover": book.get("cover", ""),
            "source_url": book.get("source_url"),
            "ai_cast": book.get("ai_cast", False), "ai_available": bool(OPENAI_API_KEY),
            "cast": book["cast"], "total_lines": total, "unlocked": unlocked,
            "preview_lines": limit,
            "lines": [dict(l, i=i) for i, l in enumerate(book["lines"][:min(200, limit)])],
            "chapters": [{"title": c["title"], "start": c["start"]}
                         for c in detect_chapters(book["lines"][:limit])],
            "provider": provider()}


def authorized_book(request: Request, book_id: str, full: bool = False) -> tuple[dict, bool]:
    book = load_book(book_id)
    access = require_book(request, book_id, allow_public=not book.get("private"))
    unlocked = access is None or bool(access["unlocked"])
    if full and not unlocked:
        raise HTTPException(403, "Unlock the full audiobook to continue.")
    return book, unlocked


@app.get("/api/books/{book_id}")
def get_book(request: Request, book_id: str):
    book, unlocked = authorized_book(request, book_id)
    return summary(book, unlocked)


class Recast(BaseModel):
    speaker: str
    voice: str


@app.post("/api/books/{book_id}/cast")
async def recast(request: Request, book_id: str, body: Recast):
    same_origin(request)
    book, _ = authorized_book(request, book_id)
    if body.speaker not in book["cast"] or body.voice not in EL_VOICES:
        raise HTTPException(400, "Unknown speaker or voice")
    book["cast"][body.speaker]["voice"] = body.voice
    save_book(book)
    invalidate_export(book_id)
    return book["cast"]


@app.get("/api/books/{book_id}/lines/{idx}/audio")
async def line_audio(request: Request, book_id: str, idx: int):
    book, unlocked = authorized_book(request, book_id)
    total = len(book["lines"])
    limit = total if unlocked else min(PREVIEW_LINES, total)
    if idx < 0 or idx >= limit:
        raise HTTPException(403, "This part of the book isn't available.")
    if provider() == "browser":
        return Response(status_code=204)  # demo mode: client speaks it
    line = book["lines"][idx]
    voice = book["cast"].get(line["speaker"], book["cast"]["Narrator"])["voice"]
    try:
        audio = await tts(book_id, line["text"], voice, line["emotion"])
    except httpx.RequestError as exc:
        raise HTTPException(502, "The voice provider could not be reached. Try again.") from exc
    return Response(audio, media_type="audio/mpeg", headers={"Cache-Control": "private, no-store"})


# ----------------------------------------------------------------------------
# Full audiobook export
# ----------------------------------------------------------------------------
CHAPTER_RE = re.compile(r"^(chapter|part|book|prologue|epilogue|act)\b[\s\w:.\-–—]{0,60}$", re.I)
EXPORTS = DATA / "exports"
EXPORTS.mkdir(parents=True, exist_ok=True)
JOBS: dict[str, dict] = {}
EXPORT_TASKS: dict[str, asyncio.Task] = {}
SEM = asyncio.Semaphore(int(os.getenv("EXPORT_CONCURRENCY", "4")))


def detect_chapters(lines: list[dict]) -> list[dict]:
    chapters = []
    for i, l in enumerate(lines):
        if l["speaker"] == "Narrator" and len(l["text"]) < 70 and CHAPTER_RE.match(l["text"].strip()):
            chapters.append({"title": l["text"].strip(), "start": i})
    if not chapters or chapters[0]["start"] > 0:
        chapters.insert(0, {"title": "Opening" if chapters else "Full story", "start": 0})
    for n, c in enumerate(chapters):
        c["end"] = chapters[n + 1]["start"] if n + 1 < len(chapters) else len(lines)
    return chapters


def safe(name: str) -> str:
    return re.sub(r"[^\w\- ]", "", name).strip().replace(" ", "_")[:60] or "audiobook"


def invalidate_export(book_id: str):
    task = EXPORT_TASKS.pop(book_id, None)
    if task:
        task.cancel()
    JOBS.pop(book_id, None)
    (EXPORTS / f"{book_id}.zip").unlink(missing_ok=True)


async def run_export(book: dict, job: dict):
    book_id = book["id"]
    lines = book["lines"]
    cast = {name: character.copy() for name, character in book["cast"].items()}
    out = EXPORTS / f"{book_id}.zip"
    temp = EXPORTS / f"{book_id}.{uuid.uuid4().hex}.tmp"

    async def render(i: int) -> bytes:
        l = lines[i]
        voice = cast.get(l["speaker"], cast["Narrator"])["voice"]
        async with SEM:
            for attempt in range(3):
                try:
                    data = await tts(book_id, l["text"], voice, l["emotion"])
                    break
                except Exception:
                    if attempt == 2:
                        raise
                    await asyncio.sleep(2 * (attempt + 1))
        job["done"] += 1
        return data

    try:
        chapters = detect_chapters(lines)
        with zipfile.ZipFile(temp, "w", zipfile.ZIP_STORED) as archive:
            with (EXPORTS / f"{temp.stem}.mp3").open("w+b") as full:
                for n, chapter in enumerate(chapters, 1):
                    with archive.open(f"{n:02d} - {safe(chapter['title'])}.mp3", "w") as chapter_mp3:
                        for first in range(chapter["start"], chapter["end"], 8):
                            indices = range(first, min(first + 8, chapter["end"]))
                            audio = await asyncio.gather(*(render(i) for i in indices))
                            for data in audio:
                                full.write(data)
                                chapter_mp3.write(data)
                archive.write(full.name, f"{safe(book['title'])} - Full.mp3")
            archive.writestr("chapters.json", json.dumps([
                {"n": n, "title": c["title"], "lines": c["end"] - c["start"]}
                for n, c in enumerate(chapters, 1)
            ], indent=2))
        temp.replace(out)
        job.update(state="ready", chapters=len(chapters), size_mb=round(out.stat().st_size / 1e6, 1))
    except Exception:
        job.update(state="error", error="Audio generation failed. Try the export again.")
    finally:
        temp.unlink(missing_ok=True)
        (EXPORTS / f"{temp.stem}.mp3").unlink(missing_ok=True)
        if EXPORT_TASKS.get(book_id) is asyncio.current_task():
            EXPORT_TASKS.pop(book_id, None)


@app.post("/api/books/{book_id}/export")
async def start_export(request: Request, book_id: str):
    same_origin(request)
    book, _ = authorized_book(request, book_id, full=True)
    if provider() == "browser":
        raise HTTPException(400, "Export needs an ElevenLabs or OpenAI key. Browser voices can't be recorded.")
    job = JOBS.get(book_id)
    if job and job["state"] in ("running", "ready"):
        return job
    if (EXPORTS / f"{book_id}.zip").exists():
        return {"state": "ready"}
    chars = sum(len(l["text"]) for l in book["lines"])
    if chars > MAX_EXPORT_CHARS:
        raise HTTPException(400, f"This book is {chars:,} characters; the export limit is {MAX_EXPORT_CHARS:,}.")
    JOBS[book_id] = {"state": "running", "done": 0, "total": len(book["lines"]), "chars": chars}
    EXPORT_TASKS[book_id] = asyncio.create_task(run_export(book, JOBS[book_id]))
    return JOBS[book_id]


@app.get("/api/books/{book_id}/export")
def export_status(request: Request, book_id: str):
    book, _ = authorized_book(request, book_id, full=True)
    if book_id in JOBS:
        return JOBS[book_id]
    if (EXPORTS / f"{book_id}.zip").exists():
        return {"state": "ready"}
    return {"state": "none", "total": len(book["lines"]),
            "chars": sum(len(l["text"]) for l in book["lines"]),
            "chapters": len(detect_chapters(book["lines"]))}


@app.get("/api/books/{book_id}/export/download")
def export_download(request: Request, book_id: str):
    book, _ = authorized_book(request, book_id, full=True)
    out = EXPORTS / f"{book['id']}.zip"
    if not out.exists():
        raise HTTPException(404, "Export not ready yet")
    return FileResponse(out, media_type="application/zip", filename=f"{safe(book['title'])}_audiobook.zip")


# ----------------------------------------------------------------------------
# Classics use the exact Project Gutenberg edition ID, and each reader has a private copy.
class OpenBook(BaseModel):
    id: int


@app.get("/api/catalog")
@app.get("/api/library/search")
async def library_search(q: str = "", page: int = 0):
    if len(q) > 120:
        raise HTTPException(400, "Search using up to 120 characters.")
    items, next_page = await search_catalog(q.strip(), page=max(0, page))
    return {"query": q.strip(), "items": items, "next_page": next_page}


@app.get("/api/library/featured")
async def library_featured():
    items, _ = await search_catalog("")
    return {"items": items}


@app.post("/api/library/open")
async def library_open(request: Request, response: Response, body: OpenBook):
    return await open_catalog_book(request, response, body.id)


@app.post("/api/catalog/{book_id}/open")
async def open_catalog_book(request: Request, response: Response, book_id: int):
    same_origin(request)
    owner = browser_owner(request, response)
    source = f"gutenberg:{book_id}"
    current = owned_catalog_book(owner, source)
    if current:
        return summary(load_book(current))

    meta, story = await load_catalog_book(book_id)
    if len(story) > MAX_CATALOG_CHARS:
        raise HTTPException(413, "This edition exceeds the classics length limit. Select a shorter book.")
    lines, genders = await asyncio.to_thread(cast_classic, story)
    lines = split_long_lines(lines)
    if not lines:
        raise HTTPException(422, "This edition has no readable text.")
    new_id = str(uuid.uuid4())
    book = {"id": new_id, "title": meta["title"], "lines": lines,
            "cast": assign_voices(lines, story, genders), "words": len(story.split()),
            "author": ", ".join(meta["authors"]), "cover": meta.get("cover") or "",
            "source": source, "source_url": meta["source"], "private": True}
    # A reader cannot see an unfinished copy. Concurrent requests reuse the committed one.
    save_book(book)
    try:
        selected = attach_book(new_id, owner, book["title"], book["author"], book["cover"],
                               unlocked=True, catalog_source=source)
    except Exception:
        remove_book(new_id)
        raise
    if selected != new_id:
        remove_book(new_id)
        book = load_book(selected)
    return summary(book)


# ----------------------------------------------------------------------------
# AI casting check for the whole book
# ----------------------------------------------------------------------------
AI_JOBS: dict[str, dict] = {}
AI_TASKS: dict[str, asyncio.Task] = {}
AI_SEM = asyncio.Semaphore(int(os.getenv("AI_CAST_CONCURRENCY", "4")))
AI_PROMPT = (
    "You are checking speaker attribution in an audiobook script. Each DIALOGUE line shows a guessed "
    "speaker, which may be wrong. Using the narration around it, decide who actually speaks each DIALOGUE "
    "line and the emotion it should be performed with. Rules: use the exact names from KNOWN CHARACTERS "
    "when they apply; if a first-person narrator speaks ('I said', 'I asked'), the speaker is Narrator; "
    "'said he' / 'said she' refers to someone in the current scene; untagged lines in a two-person "
    "exchange alternate; only invent a new name when a clearly new character speaks. "
    f"Emotion must be one of {EMOTIONS}. "
    'Return JSON {"lines":[{"i":<index>,"speaker":"<name>","emotion":"<emotion>"}],'
    '"characters":{"<name>":{"gender":"male|female"}}} with one entry for every DIALOGUE line.'
)


def is_dialogue(l: dict) -> bool:
    return bool(l.get("d")) or l["speaker"] != "Narrator"


def script_chunks(lines: list[dict], size: int = 6000) -> list[list[int]]:
    chunks, cur, n = [], [], 0
    for i, l in enumerate(lines):
        cur.append(i)
        n += len(l["text"]) + 30
        if (n >= size and not is_dialogue(l)) or n >= size * 1.5:
            chunks.append(cur)
            cur, n = [], 0
    if cur:
        chunks.append(cur)
    return [c for c in chunks if any(is_dialogue(lines[i]) for i in c)]


async def ai_fix_chunk(lines: list[dict], idxs: list[int], roster: dict) -> tuple[list, dict]:
    body = "\n".join(
        f"[{i}] DIALOGUE (guess: {lines[i]['speaker']}): {lines[i]['text']}" if is_dialogue(lines[i])
        else f"[{i}] NARRATION: {lines[i]['text']}" for i in idxs)
    roster_txt = ", ".join(f"{n} ({g})" for n, g in roster.items()) or "none yet"
    for attempt in range(3):
        try:
            async with AI_SEM:
                async with httpx.AsyncClient(timeout=120) as c:
                    r = await c.post("https://api.openai.com/v1/chat/completions",
                                     headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
                                     json={"model": os.getenv("OPENAI_CAST_MODEL", "gpt-4o-mini"),
                                           "temperature": 0, "response_format": {"type": "json_object"},
                                           "messages": [{"role": "system", "content": AI_PROMPT},
                                                        {"role": "user", "content":
                                                         f"KNOWN CHARACTERS: {roster_txt}\n\nSCRIPT:\n{body}"}]})
            r.raise_for_status()
            data = json.loads(r.json()["choices"][0]["message"]["content"])
            return data.get("lines", []), data.get("characters", {})
        except Exception:
            if attempt == 2:
                raise
            await asyncio.sleep(2 * (attempt + 1))
    return [], {}


async def run_ai_cast(book_id: str):
    job = AI_JOBS[book_id]
    try:
        book = load_book(book_id)
        lines = [line.copy() for line in book["lines"]]
        roster = {n: c.get("gender", "male") for n, c in book["cast"].items() if n != "Narrator"}
        alias = {}
        for n in roster:
            alias[n.lower()] = n
            alias.setdefault(n.split()[-1].lower(), n)
        genders = {n: {"gender": g} for n, g in roster.items()}
        chunks = script_chunks(lines)
        job["total"] = len(chunks)
        changed = 0

        async def one(idxs):
            nonlocal changed
            try:
                fixes, chars = await ai_fix_chunk(lines, idxs, roster)
            except Exception as e:
                job["failed"] += 1
                job["last_error"] = str(e)[:200]
                return
            allowed = {i for i in idxs if is_dialogue(lines[i])}
            for f in fixes if isinstance(fixes, list) else []:
                try:
                    i = int(f.get("i"))
                except (TypeError, ValueError):
                    continue
                sp = str(f.get("speaker") or "").strip()
                if i not in allowed or not sp:
                    continue
                if sp.lower() in ("narrator", "i", "me", "the narrator"):
                    sp = "Narrator"
                else:
                    sp = alias.get(sp.lower()) or alias.get(sp.split()[-1].lower()) or sp
                if sp != lines[i]["speaker"]:
                    changed += 1
                    lines[i]["speaker"] = sp
                if f.get("emotion") in EMOTIONS:
                    lines[i]["emotion"] = f["emotion"]
                lines[i]["d"] = True
            for n, v in (chars or {}).items():
                k = alias.get(str(n).lower(), n)
                if k not in genders and isinstance(v, dict) and v.get("gender") in ("male", "female"):
                    genders[k] = v
            job["done"] += 1

        await asyncio.gather(*(one(c) for c in chunks))
        if chunks and job["failed"] == len(chunks):
            raise RuntimeError(job.get("last_error") or "The AI service didn't respond")

        latest = load_book(book_id)            # keep any voice changes made while we worked
        new_cast = assign_voices(lines, "", genders)
        for n, c in new_cast.items():
            if n in latest["cast"]:
                c["voice"] = latest["cast"][n]["voice"]
        latest.update(lines=lines, cast=new_cast, ai_cast=True, ai_changed=changed)
        save_book(latest)
        invalidate_export(book_id)
        job.update(state="done", changed=changed)
    except Exception as e:
        job.update(state="error", error="Casting review failed. Try again.")
    finally:
        if AI_TASKS.get(book_id) is asyncio.current_task():
            AI_TASKS.pop(book_id, None)


def start_ai_cast(book_id: str) -> dict:
    if not OPENAI_API_KEY:
        raise HTTPException(400, "Add OPENAI_API_KEY to .env to check casting with AI.")
    j = AI_JOBS.get(book_id)
    if j and j["state"] == "running":
        return j
    AI_JOBS[book_id] = {"state": "running", "done": 0, "total": 0, "failed": 0}
    AI_TASKS[book_id] = asyncio.create_task(run_ai_cast(book_id))
    return AI_JOBS[book_id]


@app.post("/api/books/{book_id}/ai-cast")
async def ai_cast_start(request: Request, book_id: str):
    same_origin(request)
    authorized_book(request, book_id, full=True)
    return start_ai_cast(book_id)


@app.get("/api/books/{book_id}/ai-cast")
def ai_cast_status(request: Request, book_id: str):
    book, _ = authorized_book(request, book_id, full=True)
    if not OPENAI_API_KEY:
        return {"state": "unavailable"}
    j = AI_JOBS.get(book_id)
    if j and j["state"] in ("running", "error"):
        return j
    if book.get("ai_cast"):
        return {"state": "done", "changed": book.get("ai_changed", 0)}
    dialogue = sum(1 for l in book["lines"] if is_dialogue(l))
    chars = sum(len(l["text"]) for l in book["lines"])
    cost = chars / 4 * 0.15e-6 + dialogue * 25 * 0.6e-6     # gpt-4o-mini list prices
    return {"state": "none", "dialogue": dialogue, "cost": max(round(cost, 2), 0.01)}


@app.get("/api/books/{book_id}/lines")
def book_lines(request: Request, book_id: str, start: int = 0, count: int = 200):
    book, unlocked = authorized_book(request, book_id)
    total = len(book["lines"])
    limit = total if unlocked else min(PREVIEW_LINES, total)
    start, count = max(0, start), max(1, min(count, 500))
    return {"total": total, "available": limit,
            "lines": [dict(line, i=i) for i, line in enumerate(book["lines"][start:min(start + count, limit)], start)]}


def remove_book(book_id: str):
    invalidate_export(book_id)
    task = AI_TASKS.pop(book_id, None)
    if task:
        task.get_loop().call_soon_threadsafe(task.cancel)
    AI_JOBS.pop(book_id, None)
    _BOOK_CACHE.pop(book_id, None)
    (BOOKS / f"{book_id}.json").unlink(missing_ok=True)
    directory = CACHE / book_id
    if directory.is_dir():
        shutil.rmtree(directory)


set_book_remover(remove_book)


STATIC = BASE / "static"
app.mount("/static", StaticFiles(directory=STATIC), name="static")


@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")
