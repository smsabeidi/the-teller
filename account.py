"""Browser sessions, personal audiobooks, sign-in, and optional Checkout."""

import asyncio
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import smtplib
import sqlite3
import ssl
import threading
import time
from contextlib import contextmanager
from email.message import EmailMessage
from html import escape
from pathlib import Path
from typing import Callable
from urllib.parse import urlencode, urlsplit

import httpx
from fastapi import APIRouter, Form, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.routing import APIRoute
from pydantic import BaseModel

COOKIE = "voiceemo_session"
SESSION_AGE = 90 * 24 * 60 * 60
CHALLENGE_AGE = 15 * 60
OAUTH = {
    "google": {
        "authorize": "https://accounts.google.com/o/oauth2/v2/auth",
        "token": "https://oauth2.googleapis.com/token",
        "profile": "https://openidconnect.googleapis.com/v1/userinfo",
        "issuer": "https://accounts.google.com",
        "scope": "openid profile email",
    },
    "discord": {
        "authorize": "https://discord.com/oauth2/authorize",
        "token": "https://discord.com/api/oauth2/token",
        "profile": "https://discord.com/api/v10/users/@me",
        "issuer": "https://discord.com",
        "scope": "identify email",
    },
}

SCHEMA = """
CREATE TABLE IF NOT EXISTS owners (
    id TEXT PRIMARY KEY,
    provider TEXT,
    subject TEXT,
    email TEXT,
    name TEXT,
    merged_into TEXT REFERENCES owners(id),
    UNIQUE(provider, subject)
);
CREATE TABLE IF NOT EXISTS browser_sessions (
    digest TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES owners(id),
    expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS personal_books (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES owners(id),
    title TEXT NOT NULL,
    author TEXT NOT NULL,
    cover TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    unlocked INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS personal_books_by_owner ON personal_books(owner_id, deleted, created_at);
CREATE TABLE IF NOT EXISTS sign_in_challenges (
    digest TEXT PRIMARY KEY,
    session_digest TEXT NOT NULL REFERENCES browser_sessions(digest) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    data TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS checkout_orders (
    id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL REFERENCES personal_books(id),
    owner_id TEXT NOT NULL REFERENCES owners(id),
    price_id TEXT NOT NULL,
    session_id TEXT UNIQUE,
    url TEXT,
    state TEXT NOT NULL DEFAULT 'open'
);
CREATE UNIQUE INDEX IF NOT EXISTS one_open_checkout_per_book ON checkout_orders(book_id) WHERE state = 'open';
CREATE TABLE IF NOT EXISTS subscription_orders (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES owners(id),
    plan TEXT NOT NULL,
    price_id TEXT NOT NULL,
    allowance INTEGER NOT NULL,
    book_id TEXT REFERENCES personal_books(id),
    session_id TEXT UNIQUE,
    url TEXT,
    subscription_id TEXT UNIQUE,
    customer_id TEXT,
    state TEXT NOT NULL DEFAULT 'open'
);
CREATE UNIQUE INDEX IF NOT EXISTS one_subscription_per_owner ON subscription_orders(owner_id)
    WHERE state IN ('open', 'active');
CREATE TABLE IF NOT EXISTS subscription_credits (
    period_id TEXT PRIMARY KEY,
    invoice_id TEXT NOT NULL UNIQUE,
    order_id TEXT NOT NULL REFERENCES subscription_orders(id),
    starts_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    balance INTEGER NOT NULL CHECK(balance >= 0)
);
CREATE TABLE IF NOT EXISTS email_limits (
    key TEXT PRIMARY KEY,
    window INTEGER NOT NULL,
    sends INTEGER NOT NULL
);
"""


class PrivateRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def private_handler(request: Request) -> Response:
            try:
                response = await handler(request)
            except HTTPException as error:
                error.headers = {**(error.headers or {}), "Cache-Control": "private, no-store"}
                raise
            response.headers["Cache-Control"] = "private, no-store"
            response.headers.setdefault("Referrer-Policy", "no-referrer")
            return response

        return private_handler


router = APIRouter(route_class=PrivateRoute)
_book_remover: Callable[[str], None] | None = None
_initialized_path: Path | None = None
_schema_lock = threading.Lock()


def set_book_remover(remover: Callable[[str], None]) -> None:
    global _book_remover
    _book_remover = remover


@contextmanager
def database():
    global _initialized_path
    path = Path(os.getenv("VOICEEMO_DATA_DIR") or Path(__file__).parent / "data") / "accounts.sqlite3"
    if _initialized_path != path:
        path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=10)
    try:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        if _initialized_path != path:
            with _schema_lock:
                if _initialized_path != path:
                    db.execute("PRAGMA journal_mode=WAL")
                    db.executescript(SCHEMA)
                    _initialized_path = path
        with db:
            yield db
    finally:
        db.close()


def setting(name: str) -> str:
    return os.getenv(name, "").strip()


def base_url() -> str:
    url = setting("PUBLIC_BASE_URL").rstrip("/")
    try:
        parsed = urlsplit(url)
    except ValueError:
        return ""
    is_local = parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if parsed.path or parsed.query or parsed.fragment or parsed.username is not None or not parsed.hostname:
        return ""
    return url if parsed.scheme == "https" or (parsed.scheme == "http" and is_local) else ""


def credentials(provider: str) -> tuple[str, str]:
    return setting(f"{provider.upper()}_CLIENT_ID"), setting(f"{provider.upper()}_CLIENT_SECRET")


def auth_providers() -> list[str]:
    if not base_url():
        return []
    providers = [provider for provider in OAUTH if all(credentials(provider))]
    if setting("SMTP_HOST") and setting("SMTP_FROM"):
        providers.append("email")
    return providers


def billing_enabled() -> bool:
    return bool(base_url() and setting("STRIPE_SECRET_KEY") and setting("STRIPE_WEBHOOK_SECRET")
                and (setting("STRIPE_BOOK_PRICE_ID") or configured_plans()))


def configured_plans() -> dict:
    plans = {}
    for plan, name in (("weekly", "Weekly"), ("monthly", "Monthly"), ("annual", "Annual")):
        price = setting(f"STRIPE_{plan.upper()}_PRICE_ID")
        raw_allowance = setting(f"STRIPE_{plan.upper()}_BOOKS") or "1"
        if price and re.fullmatch(r"[1-9][0-9]{0,3}", raw_allowance):
            plans[plan] = {"id": plan, "name": name, "books_per_period": int(raw_allowance), "price_id": price}
    return plans


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def session(request: Request) -> sqlite3.Row | None:
    if hasattr(request.state, "voiceemo_session"):
        return request.state.voiceemo_session
    cookie = request.cookies.get(COOKIE, "")
    row = None
    if re.fullmatch(r"[A-Za-z0-9_-]{43}", cookie):
        with database() as db:
            row = db.execute(
                "SELECT o.*, s.digest FROM browser_sessions s JOIN owners o ON o.id=s.owner_id "
                "WHERE s.digest=? AND s.expires_at>? AND o.merged_into IS NULL", (digest(cookie), int(time.time()))
            ).fetchone()
    request.state.voiceemo_session = row
    return row


def new_session(db, owner_id: str, request: Request, response: Response) -> None:
    token = secrets.token_urlsafe(32)
    db.execute("DELETE FROM browser_sessions WHERE expires_at <= ?", (int(time.time()),))
    db.execute("INSERT INTO browser_sessions VALUES (?, ?, ?)", (digest(token), owner_id, int(time.time()) + SESSION_AGE))
    secure = (base_url() or str(request.url)).startswith("https://")
    response.set_cookie(COOKIE, token, httponly=True, secure=secure, samesite="lax", max_age=SESSION_AGE)
    request.state.voiceemo_session = db.execute(
        "SELECT owners.*, ? AS digest FROM owners WHERE id=?", (digest(token), owner_id)
    ).fetchone()


def browser_owner(request: Request, response: Response) -> str:
    current = session(request)
    if current is not None:
        return current["id"]
    owner_id = secrets.token_hex(16)
    with database() as db:
        db.execute("INSERT INTO owners(id) VALUES (?)", (owner_id,))
        new_session(db, owner_id, request, response)
    return owner_id


def attach_book(book_id: str, owner_id: str, title: str, author: str = "", cover: str = "") -> None:
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        owner = db.execute("SELECT merged_into FROM owners WHERE id=?", (owner_id,)).fetchone()
        db.execute(
            "INSERT INTO personal_books(id, owner_id, title, author, cover, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (book_id, owner["merged_into"] or owner_id, title, author, cover, int(time.time())),
        )


def require_book(request: Request, book_id: str, *, allow_public: bool = True) -> sqlite3.Row | None:
    with database() as db:
        row = db.execute("SELECT * FROM personal_books WHERE id=?", (book_id,)).fetchone()
    if row is None and allow_public:
        return None
    current = session(request)
    if row is None or row["deleted"] or current is None or row["owner_id"] != current["id"]:
        raise HTTPException(404, "Book not found.")
    return row


def playback_unlocked(request: Request, book_id: str) -> bool:
    row = require_book(request, book_id)
    return row is None or bool(row["unlocked"])


def same_origin(request: Request) -> None:
    origin = request.headers.get("origin")
    expected = base_url() or f"{request.url.scheme}://{request.url.netloc}"
    if (origin is not None and origin != expected) or request.headers.get("sec-fetch-site") == "cross-site":
        raise HTTPException(403, "Open VoiceEmo Studio directly and try again.")


def eligible_credits(db, owner_id: str):
    now = int(time.time())
    return db.execute(
        "SELECT c.* FROM subscription_credits c JOIN subscription_orders o ON o.id=c.order_id "
        "WHERE o.owner_id=? AND c.starts_at<=? AND c.expires_at>? AND c.balance>0 "
        "ORDER BY c.expires_at, c.period_id", (owner_id, now, now)
    ).fetchall()


@router.get("/api/account")
def account_status(request: Request, response: Response):
    owner_id = browser_owner(request, response)
    current = session(request)
    with database() as db:
        balance = sum(row["balance"] for row in eligible_credits(db, owner_id))
        subscription = db.execute("SELECT 1 FROM subscription_orders WHERE owner_id=? AND state='active'",
                                  (owner_id,)).fetchone()
        stripe_customer = db.execute("SELECT 1 FROM subscription_orders WHERE owner_id=? AND customer_id IS NOT NULL",
                                     (owner_id,)).fetchone()
    checkout_enabled = billing_enabled()
    plans = [{key: value for key, value in plan.items() if key != "price_id"}
             for plan in configured_plans().values()] if checkout_enabled else []
    return {"signed_in": current["provider"] is not None, "email": current["email"], "name": current["name"],
            "providers": auth_providers(), "billing_enabled": checkout_enabled, "plans": plans, "credits": balance,
            "one_off_available": checkout_enabled and bool(setting("STRIPE_BOOK_PRICE_ID")),
            "can_manage_billing": bool(base_url() and setting("STRIPE_SECRET_KEY") and stripe_customer),
            "has_subscription": subscription is not None}


@router.get("/api/my/books")
def personal_library(request: Request, response: Response):
    owner_id = browser_owner(request, response)
    with database() as db:
        books = db.execute(
            "SELECT id, title, author, cover, created_at, unlocked FROM personal_books "
            "WHERE owner_id=? AND deleted=0 ORDER BY created_at DESC, rowid DESC", (owner_id,)
        ).fetchall()
    return {"books": [dict(book, unlocked=bool(book["unlocked"])) for book in books]}


@router.delete("/api/my/books/{book_id}")
async def delete_book(request: Request, book_id: str):
    same_origin(request)
    row = require_book(request, book_id, allow_public=False)
    with database() as db:
        result = db.execute("UPDATE personal_books SET deleted=1, title='', author='', cover='' "
                            "WHERE id=? AND owner_id=? AND deleted=0", (book_id, row["owner_id"]))
        if result.rowcount != 1:
            raise HTTPException(404, "Book not found.")
    if _book_remover is not None:
        _book_remover(book_id)
    return {"deleted": True}


@router.post("/api/my/books/{book_id}/unlock")
def unlock_book(request: Request, book_id: str):
    same_origin(request)
    row = require_book(request, book_id, allow_public=False)
    if not row["unlocked"]:
        if billing_enabled():
            raise HTTPException(402, "Complete checkout to unlock the full audiobook.")
        with database() as db:
            result = db.execute("UPDATE personal_books SET unlocked=1 WHERE id=? AND owner_id=? AND deleted=0",
                                (book_id, row["owner_id"]))
            if result.rowcount != 1:
                raise HTTPException(404, "Book not found.")
    return {"unlocked": True}


@router.post("/api/my/books/{book_id}/spend-credit")
def spend_credit(request: Request, book_id: str):
    same_origin(request)
    book = require_book(request, book_id, allow_public=False)
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT unlocked, deleted FROM personal_books WHERE id=? AND owner_id=?",
                         (book_id, book["owner_id"])).fetchone()
        if row is None or row["deleted"]:
            raise HTTPException(404, "Book not found.")
        credits = eligible_credits(db, book["owner_id"])
        balance = sum(credit["balance"] for credit in credits)
        if not row["unlocked"]:
            if not credits:
                raise HTTPException(402, "Your account has no audiobook credits available.")
            order = db.execute("SELECT 1 FROM checkout_orders WHERE book_id=? AND state='open'", (book_id,)).fetchone()
            if order is not None:
                raise HTTPException(409, "There is already a one-time checkout for this book. Wait for it to expire before using a credit.")
            db.execute("UPDATE subscription_credits SET balance=balance-1 WHERE period_id=?", (credits[0]["period_id"],))
            db.execute("UPDATE personal_books SET unlocked=1 WHERE id=?", (book_id,))
            balance -= 1
    return {"unlocked": True, "credits": balance}


@router.post("/api/auth/logout")
def logout(request: Request, response: Response):
    same_origin(request)
    current = session(request)
    if current is not None and current["provider"] is not None:
        with database() as db:
            db.execute("DELETE FROM browser_sessions WHERE digest=?", (current["digest"],))
        response.delete_cookie(COOKIE)
    return {"signed_in": False}


def create_challenge(request: Request, provider: str, data: str) -> str:
    token = secrets.token_urlsafe(32)
    now = int(time.time())
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM sign_in_challenges WHERE expires_at <= ?", (now,))
        session_digest = session(request)["digest"]
        pending = db.execute("SELECT COUNT(*) FROM sign_in_challenges WHERE session_digest=?", (session_digest,)).fetchone()
        if pending[0] >= 15:
            raise HTTPException(429, "Too many sign-in attempts. Wait a few minutes and try again.")
        db.execute("INSERT INTO sign_in_challenges VALUES (?, ?, ?, ?, ?)",
                   (digest(token), session_digest, provider, data, now + CHALLENGE_AGE))
    return token


def get_challenge(request: Request, provider: str, token: str, *, consume: bool) -> str:
    current = session(request)
    if current is None or not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
        raise HTTPException(400, "This sign-in link has expired. Start sign-in again in this browser.")
    hashed_token = digest(token)
    with database() as db:
        if consume:
            db.execute("BEGIN IMMEDIATE")
        row = db.execute(
            "SELECT data FROM sign_in_challenges WHERE digest=? AND provider=? AND session_digest=? AND expires_at>?",
            (hashed_token, provider, current["digest"], int(time.time()))
        ).fetchone()
        if row is None:
            raise HTTPException(400, "This sign-in link has expired. Start sign-in again in this browser.")
        if consume:
            db.execute("DELETE FROM sign_in_challenges WHERE digest=?", (hashed_token,))
    return row["data"]


def complete_sign_in(request: Request, provider: str, subject: str, email: str, name: str) -> Response:
    current = session(request)
    redirect = RedirectResponse("/?auth=success", status_code=303)
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        owner = db.execute("SELECT id FROM owners WHERE provider=? AND subject=?", (provider, subject)).fetchone()
        if owner is None:
            owner_id = secrets.token_hex(16)
            db.execute("INSERT INTO owners(id, provider, subject, email, name) VALUES (?, ?, ?, ?, ?)",
                       (owner_id, provider, subject, email, name))
        else:
            owner_id = owner["id"]
            db.execute("UPDATE owners SET email=?, name=? WHERE id=?", (email, name, owner_id))
        if current["provider"] is None:
            db.execute("UPDATE personal_books SET owner_id=? WHERE owner_id=?", (owner_id, current["id"]))
            db.execute("UPDATE owners SET merged_into=? WHERE id=?", (owner_id, current["id"]))
        db.execute("DELETE FROM browser_sessions WHERE digest=?", (current["digest"],))
        new_session(db, owner_id, request, redirect)
    return redirect


@router.get("/api/auth/{provider}/start")
def oauth_start(request: Request, provider: str):
    if provider not in OAUTH or provider not in auth_providers():
        raise HTTPException(404, "This sign-in method is unavailable.")
    response = RedirectResponse("/", status_code=303)
    browser_owner(request, response)
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    state = create_challenge(request, provider, verifier)
    client_id, _ = credentials(provider)
    params = {"client_id": client_id, "response_type": "code", "scope": OAUTH[provider]["scope"],
              "redirect_uri": f"{base_url()}/api/auth/{provider}/callback", "state": state,
              "code_challenge": challenge, "code_challenge_method": "S256"}
    response.headers["Location"] = f"{OAUTH[provider]['authorize']}?{urlencode(params)}"
    return response


@router.get("/api/auth/{provider}/callback")
async def oauth_callback(request: Request, provider: str, state: str = "", code: str = "", iss: str = ""):
    if provider not in OAUTH or provider not in auth_providers():
        raise HTTPException(404, "This sign-in method is unavailable.")
    verifier = get_challenge(request, provider, state, consume=True)
    if not code or (iss and iss != OAUTH[provider]["issuer"]):
        return RedirectResponse("/?auth=failed", status_code=303)
    client_id, client_secret = credentials(provider)
    fields = {"grant_type": "authorization_code", "code": code, "code_verifier": verifier,
              "redirect_uri": f"{base_url()}/api/auth/{provider}/callback"}
    try:
        async with httpx.AsyncClient(timeout=15, trust_env=False) as client:
            token = await client.post(OAUTH[provider]["token"], data={**fields, "client_id": client_id,
                                                                    "client_secret": client_secret})
            token.raise_for_status()
            access = token.json()["access_token"]
            user = await client.get(OAUTH[provider]["profile"], headers={"Authorization": f"Bearer {access}"})
            user.raise_for_status()
            profile = user.json()
            if provider == "google":
                subject, name, verified = profile["sub"], profile.get("name"), profile.get("email_verified")
            else:
                subject, name, verified = profile["id"], profile.get("global_name") or profile.get("username"), profile.get("verified")
            if not isinstance(subject, str) or not subject:
                raise ValueError("Missing user identifier")
            email = (profile.get("email") or "") if verified is True else ""
    except (httpx.HTTPError, KeyError, ValueError, TypeError, AttributeError):
        return RedirectResponse("/?auth=failed", status_code=303)
    return complete_sign_in(request, provider, subject, email, name or email or provider.title())


class EmailSignIn(BaseModel):
    email: str


def email_limit(email: str, ip: str) -> None:
    hour = int(time.time()) // 3600
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM email_limits WHERE window < ?", (hour,))
        for key, limit in ((f"email:{digest(email)}", 4), (f"ip:{digest(ip)}", 20)):
            previous = db.execute("SELECT sends FROM email_limits WHERE key=?", (key,)).fetchone()
            if previous is not None and previous["sends"] >= limit:
                raise HTTPException(429, "Too many sign-in emails. Try again later.")
            db.execute("INSERT INTO email_limits VALUES (?, ?, 1) ON CONFLICT(key) DO UPDATE SET sends=sends+1", (key, hour))


def send_link(email: str, token: str) -> None:
    security = setting("SMTP_SECURITY") or "starttls"
    if security not in {"starttls", "tls"}:
        raise ValueError("SMTP_SECURITY must be starttls or tls")
    host = setting("SMTP_HOST")
    port = int(setting("SMTP_PORT") or ("465" if security == "tls" else "587"))
    context = ssl.create_default_context()
    message = EmailMessage()
    message["From"] = setting("SMTP_FROM")
    message["To"] = email
    message["Subject"] = "Sign in to VoiceEmo Studio"
    message.set_content(f"Open this link in the browser where you requested it. It expires in 15 minutes.\n\n"
                        f"{base_url()}/api/auth/email/confirm?{urlencode({'token': token})}\n")
    connection = (smtplib.SMTP_SSL(host, port, context=context, timeout=15) if security == "tls"
                  else smtplib.SMTP(host, port, timeout=15))
    with connection as client:
        if security == "starttls":
            client.starttls(context=context)
        if setting("SMTP_USERNAME"):
            client.login(setting("SMTP_USERNAME"), setting("SMTP_PASSWORD"))
        client.send_message(message)


@router.post("/api/auth/email")
async def email_sign_in(request: Request, response: Response, body: EmailSignIn):
    same_origin(request)
    if "email" not in auth_providers():
        raise HTTPException(404, "Email sign-in is unavailable.")
    email = body.email.strip().lower()
    if len(email) > 254 or not re.fullmatch(r"[\w.!#$%&'*+/=?^`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+", email, re.ASCII):
        raise HTTPException(400, "Enter a valid email address.")
    email_limit(email, request.client.host if request.client else "unknown")
    browser_owner(request, response)
    token = create_challenge(request, "email", email)
    try:
        await asyncio.to_thread(send_link, email, token)
    except (OSError, ValueError, smtplib.SMTPException) as error:
        raise HTTPException(502, "The sign-in email could not be sent. Try again later.") from error
    return {"sent": True}


@router.get("/api/auth/email/confirm", response_class=HTMLResponse)
def email_confirm(request: Request, token: str = ""):
    get_challenge(request, "email", token, consume=False)
    return HTMLResponse(f"""<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Sign in · VoiceEmo</title>
<main><h1>Sign in to VoiceEmo Studio</h1><form method="post" action="/api/auth/email/confirm">
<input type="hidden" name="token" value="{escape(token)}"><button type="submit">Confirm sign-in</button>
</form></main></html>""", headers={
        "Content-Security-Policy": "default-src 'none'; form-action 'self'; frame-ancestors 'none'",
        "Referrer-Policy": "same-origin",
    })


@router.post("/api/auth/email/confirm")
def email_confirm_submit(request: Request, token: str = Form(...)):
    same_origin(request)
    email = get_challenge(request, "email", token, consume=True)
    return complete_sign_in(request, "email", email, email, email.split("@", 1)[0])


class CheckoutChoice(BaseModel):
    plan: str | None = None


async def stripe_post(path: str, fields: dict, *, idempotency_key: str | None = None) -> dict:
    headers = {"Authorization": f"Bearer {setting('STRIPE_SECRET_KEY')}"}
    if idempotency_key is not None:
        headers["Idempotency-Key"] = idempotency_key
    async with httpx.AsyncClient(timeout=15, trust_env=False) as client:
        response = await client.post(f"https://api.stripe.com/v1/{path}", data=fields, headers=headers)
        response.raise_for_status()
        return response.json()


def stripe_redirect(result: dict, host: str) -> str:
    url = result["url"]
    if not isinstance(url, str) or not url.startswith(f"https://{host}/"):
        raise ValueError("Invalid Stripe redirect URL")
    return url


def checkout_owner(request: Request) -> sqlite3.Row:
    current = session(request)
    if current is None or not current["provider"]:
        raise HTTPException(401, "Sign in to continue to checkout.")
    return current


@router.post("/api/my/books/{book_id}/checkout")
async def start_checkout(request: Request, book_id: str, body: CheckoutChoice | None = None):
    same_origin(request)
    row = require_book(request, book_id, allow_public=False)
    if row["unlocked"]:
        return {"unlocked": True}
    if body and body.plan:
        return await start_subscription(request, body.plan, book_id)
    if not billing_enabled() or not setting("STRIPE_BOOK_PRICE_ID"):
        raise HTTPException(404, "Checkout is unavailable.")
    current = checkout_owner(request)
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT unlocked, deleted FROM personal_books WHERE id=?", (book_id,)).fetchone()
        if row["deleted"]:
            raise HTTPException(404, "Book not found.")
        if row["unlocked"]:
            return {"unlocked": True}
        order = db.execute("SELECT * FROM checkout_orders WHERE book_id=? AND state='open'", (book_id,)).fetchone()
        if order is None:
            order_id = secrets.token_hex(16)
            db.execute("INSERT INTO checkout_orders(id, book_id, owner_id, price_id) VALUES (?, ?, ?, ?)",
                       (order_id, book_id, current["id"], setting("STRIPE_BOOK_PRICE_ID")))
            order = db.execute("SELECT * FROM checkout_orders WHERE id=?", (order_id,)).fetchone()
    if order["url"]:
        return {"url": order["url"]}
    return_url = f"{base_url()}/?{urlencode({'book': book_id})}"
    fields = {"mode": "payment", "line_items[0][price]": order["price_id"], "line_items[0][quantity]": "1",
              "client_reference_id": order["id"], "success_url": f"{return_url}&checkout=success",
              "cancel_url": f"{return_url}&checkout=cancel"}
    try:
        checkout = await stripe_post("checkout/sessions", fields, idempotency_key=order["id"])
        checkout_url, checkout_id = stripe_redirect(checkout, "checkout.stripe.com"), checkout["id"]
    except (httpx.HTTPError, KeyError, ValueError, TypeError) as error:
        retire_rejected_checkout("checkout_orders", order["id"], error)
        raise HTTPException(502, "Checkout could not be started. Try again later.") from error
    with database() as db:
        db.execute("UPDATE checkout_orders SET session_id=?, url=? WHERE id=?", (checkout_id, checkout_url, order["id"]))
    return {"url": checkout_url}


def retire_rejected_checkout(table: str, order_id: str, error: Exception) -> None:
    if isinstance(error, httpx.HTTPStatusError) and error.response.status_code in {400, 401, 403, 404}:
        with database() as db:
            db.execute(f"UPDATE {table} SET state='rejected' WHERE id=? AND session_id IS NULL AND state='open'",
                       (order_id,))


@router.post("/api/billing/subscribe")
async def subscribe(request: Request, body: CheckoutChoice):
    same_origin(request)
    return await start_subscription(request, body.plan or "")


async def start_subscription(request: Request, plan_id: str, book_id: str | None = None):
    plan = configured_plans().get(plan_id)
    if not billing_enabled() or plan is None:
        raise HTTPException(404, "This plan is unavailable.")
    current = checkout_owner(request)
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        order = db.execute("SELECT * FROM subscription_orders WHERE owner_id=? AND state IN ('open', 'active')",
                           (current["id"],)).fetchone()
        if order is not None and order["state"] == "active":
            raise HTTPException(409, "Manage your current subscription in the billing portal.")
        if order is None:
            order_id = secrets.token_hex(16)
            db.execute("INSERT INTO subscription_orders(id, owner_id, plan, price_id, allowance, book_id) "
                       "VALUES (?, ?, ?, ?, ?, ?)",
                       (order_id, current["id"], plan_id, plan["price_id"], plan["books_per_period"], book_id))
            customer = stripe_customer(db, current["id"])
            if customer:
                db.execute("UPDATE subscription_orders SET customer_id=? WHERE id=?", (customer, order_id))
            order = db.execute("SELECT * FROM subscription_orders WHERE id=?", (order_id,)).fetchone()
    if order["plan"] != plan_id:
        raise HTTPException(409, f"You already have a checkout open for the {order['plan']} plan.")
    if order["url"]:
        return {"url": order["url"]}
    origin_book = order["book_id"]
    params = {"book": origin_book} if origin_book else {}
    fields = {
        "mode": "subscription", "line_items[0][price]": order["price_id"], "line_items[0][quantity]": "1",
        "client_reference_id": order["id"], "subscription_data[metadata][voiceemo_order]": order["id"],
        "success_url": f"{base_url()}/?{urlencode({**params, 'checkout': 'subscription'})}",
        "cancel_url": f"{base_url()}/?{urlencode({**params, 'checkout': 'cancel'})}",
    }
    if order["customer_id"]:
        fields["customer"] = order["customer_id"]
    try:
        checkout = await stripe_post("checkout/sessions", fields, idempotency_key=order["id"])
        checkout_url, checkout_id = stripe_redirect(checkout, "checkout.stripe.com"), checkout["id"]
    except (httpx.HTTPError, KeyError, ValueError, TypeError) as error:
        retire_rejected_checkout("subscription_orders", order["id"], error)
        raise HTTPException(502, "Subscription checkout could not be started. Try again later.") from error
    with database() as db:
        db.execute("UPDATE subscription_orders SET session_id=?, url=? WHERE id=?",
                   (checkout_id, checkout_url, order["id"]))
    return {"url": checkout_url}


def stripe_customer(db, owner_id: str) -> str | None:
    row = db.execute("SELECT customer_id FROM subscription_orders WHERE owner_id=? AND customer_id IS NOT NULL "
                     "ORDER BY state='active' DESC, rowid DESC LIMIT 1", (owner_id,)).fetchone()
    return row["customer_id"] if row else None


@router.post("/api/billing/portal")
async def billing_portal(request: Request):
    same_origin(request)
    current = checkout_owner(request)
    if not base_url() or not setting("STRIPE_SECRET_KEY"):
        raise HTTPException(404, "The billing portal is unavailable.")
    with database() as db:
        customer = stripe_customer(db, current["id"])
    if customer is None:
        raise HTTPException(404, "There is no subscription billing profile for this account.")
    try:
        portal = await stripe_post("billing_portal/sessions", {"customer": customer, "return_url": f"{base_url()}/"})
        return {"url": stripe_redirect(portal, "billing.stripe.com")}
    except (httpx.HTTPError, KeyError, ValueError, TypeError) as error:
        raise HTTPException(502, "The billing portal could not be opened. Try again later.") from error


def verify_stripe(payload: bytes, signature: str) -> bool:
    parts = [item.strip().split("=", 1) for item in signature.split(",") if "=" in item]
    timestamps = [value for key, value in parts if key == "t"]
    if len(timestamps) != 1 or not re.fullmatch(r"[0-9]{1,12}", timestamps[0]):
        return False
    timestamp = timestamps[0]
    if abs(time.time() - int(timestamp)) > 300:
        return False
    signed = f"{timestamp}.".encode() + payload
    expected = hmac.new(setting("STRIPE_WEBHOOK_SECRET").encode(), signed, hashlib.sha256).hexdigest()
    return any(key == "v1" and value.isascii() and hmac.compare_digest(expected, value) for key, value in parts)


@router.post("/api/stripe/webhook")
async def stripe_webhook(request: Request):
    if not billing_enabled():
        raise HTTPException(404, "Checkout is unavailable.")
    payload = bytearray()
    async for chunk in request.stream():
        payload.extend(chunk)
        if len(payload) > 1024 * 1024:
            raise HTTPException(413, "Webhook payload too large.")
    if not verify_stripe(bytes(payload), request.headers.get("stripe-signature", "")):
        raise HTTPException(400, "Invalid webhook signature.")
    try:
        event = json.loads(payload)
        event_type = event["type"]
        obj = event["data"]["object"]
        if not isinstance(obj, dict) or not isinstance(event_type, str):
            raise ValueError("Invalid event type or object")
    except (KeyError, ValueError, TypeError, AttributeError) as error:
        raise HTTPException(400, "Invalid webhook payload.") from error
    if event_type == "invoice.paid" and obj.get("object") == "invoice":
        record_paid_invoice(obj)
    elif event_type == "customer.subscription.deleted" and obj.get("object") == "subscription":
        end_subscription(obj)
    elif obj.get("object") == "checkout.session":
        apply_checkout_event(event_type, obj)
    return {"received": True}


def apply_checkout_event(event_type: str, checkout: dict) -> None:
    reference, checkout_id = checkout.get("client_reference_id"), checkout.get("id")
    if not reference or not checkout_id:
        return
    completed = event_type in {"checkout.session.completed", "checkout.session.async_payment_succeeded"}
    expired = event_type in {"checkout.session.expired", "checkout.session.async_payment_failed"}
    if checkout.get("mode") == "subscription" and (completed or expired):
        apply_subscription_checkout(checkout, reference, checkout_id, expired)
        return
    if checkout.get("mode") != "payment":
        return
    paid = completed and checkout.get("payment_status") == "paid"
    if paid or expired:
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            order = db.execute("SELECT * FROM checkout_orders WHERE id=? AND session_id=?",
                               (reference, checkout_id)).fetchone()
            if order is None:
                pending = db.execute("SELECT 1 FROM checkout_orders WHERE id=? AND session_id IS NULL", (reference,)).fetchone()
                if pending is not None:
                    raise HTTPException(503, "Checkout is still being recorded. Retry this event.")
            elif paid:
                db.execute("UPDATE checkout_orders SET state='paid' WHERE id=?", (reference,))
                db.execute("UPDATE personal_books SET unlocked=1 WHERE id=? AND owner_id=? AND deleted=0",
                           (order["book_id"], order["owner_id"]))
            elif order["state"] == "open":
                db.execute("UPDATE checkout_orders SET state='expired' WHERE id=?", (reference,))


def apply_subscription_checkout(checkout: dict, reference: str, checkout_id: str, expired: bool) -> None:
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        order = db.execute("SELECT * FROM subscription_orders WHERE id=?", (reference,)).fetchone()
        if order is None or (order["session_id"] and order["session_id"] != checkout_id):
            return
        if expired:
            db.execute("UPDATE subscription_orders SET state='expired' WHERE id=? AND state='open'", (reference,))
        elif isinstance(checkout.get("subscription"), str) and isinstance(checkout.get("customer"), str):
            if order["subscription_id"] and order["subscription_id"] != checkout["subscription"]:
                return
            db.execute("UPDATE subscription_orders SET subscription_id=?, customer_id=? WHERE id=?",
                       (checkout["subscription"], checkout["customer"], reference))


def line_price(line: dict) -> str | None:
    pricing = (line.get("pricing") or {}).get("price_details") or {}
    price = pricing.get("price") or line.get("price") or {}
    return price.get("id") if isinstance(price, dict) else price


def record_paid_invoice(invoice: dict) -> None:
    if invoice.get("status") != "paid" or invoice.get("billing_reason") not in {"subscription_create", "subscription_cycle"}:
        return
    parent = (invoice.get("parent") or {}).get("subscription_details") or invoice.get("subscription_details") or {}
    reference = (parent.get("metadata") or {}).get("voiceemo_order")
    sub_id = parent.get("subscription") or invoice.get("subscription")
    customer_id, invoice_id = invoice.get("customer"), invoice.get("id")
    if not all(isinstance(item, str) and item for item in (sub_id, customer_id, invoice_id)):
        return
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        order = db.execute("SELECT * FROM subscription_orders WHERE subscription_id=?", (sub_id,)).fetchone()
        if order is None and isinstance(reference, str):
            order = db.execute("SELECT * FROM subscription_orders WHERE id=? AND subscription_id IS NULL",
                               (reference,)).fetchone()
        if order is None or order["state"] == "expired" or (order["customer_id"] and order["customer_id"] != customer_id):
            return
        lines = (invoice.get("lines") or {}).get("data") or []
        for line in lines:
            details = (line.get("parent") or {}).get("subscription_item_details") or {}
            if details.get("proration") or line.get("proration") or line.get("quantity") != 1:
                continue
            price_id = line_price(line)
            plan = next((plan for plan in configured_plans().values() if plan["price_id"] == price_id), None)
            if price_id == order["price_id"]:
                allowance = order["allowance"]
            elif plan is not None:
                allowance = plan["books_per_period"]
            else:
                continue
            period = line.get("period") or {}
            start, end = period.get("start"), period.get("end")
            if not isinstance(start, int) or not isinstance(end, int) or start >= end:
                continue
            state = "active" if order["state"] == "open" else order["state"]
            db.execute("UPDATE subscription_orders SET state=?, subscription_id=?, customer_id=? WHERE id=?",
                       (state, sub_id, customer_id, order["id"]))
            db.execute("INSERT OR IGNORE INTO subscription_credits VALUES (?, ?, ?, ?, ?, ?)",
                       (f"{sub_id}:{start}", invoice_id, order["id"], start, end, allowance))
            break


def end_subscription(subscription: dict) -> None:
    sub_id = subscription.get("id")
    reference = (subscription.get("metadata") or {}).get("voiceemo_order")
    if not isinstance(sub_id, str) or not sub_id:
        return
    with database() as db:
        db.execute("UPDATE subscription_orders SET state='ended', subscription_id=? "
                   "WHERE subscription_id=? OR (id=? AND subscription_id IS NULL)", (sub_id, sub_id, reference))
