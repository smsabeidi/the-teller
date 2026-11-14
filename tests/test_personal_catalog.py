"""In-process API regression tests. Run with python -m unittest discover -s tests."""

import asyncio
import importlib.util
import os
import secrets
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx

import account
import book_catalog
import human_audio


class PersonalCatalogTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        path = self.enterContext(tempfile.TemporaryDirectory())
        self.access_key = secrets.token_urlsafe(32)
        self.enterContext(patch.dict(os.environ, {
            "TELLER_PERSONAL_MODE": "1",
            "TELLER_ACCESS_KEY": self.access_key,
            "VOICEEMO_DATA_DIR": path,
            "ELEVENLABS_API_KEY": "",
            "OPENAI_API_KEY": "",
            "PREVIEW_LINES": "2",
            "GUTENBERG_CATALOG_PATH": "",
            "GUTENBERG_MIRROR_URL": "",
            "PUBLIC_BASE_URL": "",
            "IMPORTS_PER_HOUR": "20",
        }))
        self.enterContext(patch.object(account, "_book_remover", None))
        self.enterContext(patch.object(account, "_initialized_path", None))
        # Isolate settings and on-disk paths from other tests that import the server.
        server_path = Path(__file__).resolve().parents[1] / "server.py"
        spec = importlib.util.spec_from_file_location("teller_personal_regression_server", server_path)
        self.server = importlib.util.module_from_spec(spec)
        with patch("dotenv.load_dotenv"):
            spec.loader.exec_module(self.server)

        self.books = Path(path) / "books"
        self.client = await self.enterAsyncContext(self.make_client())

    def make_client(self, authenticated=True):
        headers = {"Authorization": f"Bearer {self.access_key}"} if authenticated else {}
        return httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.server.app), base_url="http://testserver", headers=headers,
        )

    async def test_personal_routes_require_bearer_except_health(self):
        async with self.make_client(authenticated=False) as guest:
            self.assertEqual((await guest.get("/api/health")).status_code, 200)
            for path in ("/api/account", "/api/my/books", "/api/catalog", "/api/catalog/human", "/"):
                with self.subTest(path=path):
                    response = await guest.get(path)
                    self.assertEqual(response.status_code, 401)
                    self.assertEqual(response.headers["www-authenticate"], "Bearer")
                    self.assertEqual(response.headers["cache-control"], "no-store")
            wrong_key = await guest.get("/api/account", headers={"Authorization": "Bearer incorrect"})
            self.assertEqual(wrong_key.status_code, 401)

    async def test_cookieless_clients_share_owner_and_full_book(self):
        status = await self.client.get("/api/account")
        self.assertTrue(status.json()["personal_mode"])
        self.assertTrue(status.json()["signed_in"])
        self.assertFalse(status.json()["billing_enabled"])
        self.assertNotIn("set-cookie", status.headers)
        text = "\n\n".join(
            (f"The narrator watched as light filled the valley on day {index}." for index in range(8))
        )
        response = await self.client.post("/api/import", data={"text": text})
        self.assertEqual(response.status_code, 200, response.text)
        book = response.json()
        self.assertTrue(book["unlocked"])
        self.assertGreater(book["total_lines"], 2)
        book_id = book["id"]

        async with self.make_client() as fresh:
            library = await fresh.get("/api/my/books")
            self.assertEqual([item["id"] for item in library.json()["books"]], [book_id])
            self.assertNotIn("set-cookie", library.headers)
            lines = await fresh.get(f"/api/books/{book_id}/lines")
            self.assertEqual(lines.json()["available"], book["total_lines"])
            self.assertEqual((await fresh.get(f"/api/books/{book_id}/lines/2/audio")).status_code, 204)

        with account.database() as db:
            owners = db.execute("SELECT id FROM owners").fetchall()
            self.assertEqual([row["id"] for row in owners], [account.PERSONAL_OWNER])
            self.assertEqual(db.execute("SELECT COUNT(*) FROM browser_sessions").fetchone()[0], 0)

    async def test_web_guest_preserves_cookie_ownership_and_preview(self):
        text = "\n\n".join(
            f"The narrator watched as light filled the valley on day {index}." for index in range(8)
        )
        async with self.make_client(authenticated=False) as guest, self.make_client(authenticated=False) as other:
            with patch.dict(os.environ, {"TELLER_PERSONAL_MODE": "0"}):
                response = await guest.post("/api/import", data={"text": text})
                self.assertEqual(response.status_code, 200, response.text)
                self.assertIn(account.COOKIE, guest.cookies)
                book = response.json()
                self.assertFalse(book["unlocked"])
                route = f"/api/books/{book['id']}/lines"
                self.assertEqual((await guest.get(route)).json()["available"], 2)
                self.assertEqual((await guest.get(f"{route}/2/audio")).status_code, 403)
                self.assertEqual((await other.get(route)).status_code, 404)
                self.assertEqual((await guest.post(f"/api/my/books/{book['id']}/unlock")).status_code, 200)
                self.assertEqual((await guest.get(route)).json()["available"], book["total_lines"])

    async def test_classic_open_checks_rights_keeps_ending_and_reuses_private_copy(self):
        ending = "The final lantern went out, and the morning came at last."
        story = "\n\n".join(
            f"On day {index}, the lantern beside the harbor shone above the tide."
            for index in range(230)
        )
        ebook = f"""Gutenberg preamble that should not enter the audiobook.
*** START OF THE PROJECT GUTENBERG EBOOK PRIDE AND PREJUDICE ***
{story}

{ending}
*** END OF THE PROJECT GUTENBERG EBOOK PRIDE AND PREJUDICE ***
Gutenberg license that should not enter the audiobook.
""".encode()
        rights = b"""<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
             xmlns:pg="http://www.gutenberg.org/2009/pgterms/" xmlns:dc="http://purl.org/dc/terms/">
             <pg:ebook rdf:about="ebooks/1342"><dc:rights>Public domain in the USA.</dc:rights></pg:ebook>
             </rdf:RDF>"""
        called = []
        both_downloads = asyncio.Event()

        async def read_asset(_client, url, _limit):
            called.append(url)
            if url.endswith(".rdf"):
                return rights
            if sum(path.endswith(".txt") for path in called) == 2:
                both_downloads.set()
            await asyncio.wait_for(both_downloads.wait(), timeout=5)
            return ebook

        search = await self.client.get("/api/catalog", params={"q": "jane austen"})
        self.assertEqual(search.json()["items"][0]["id"], 1342)
        with patch.object(book_catalog, "_read_asset", read_asset):
            first, second = await asyncio.gather(
                self.client.post("/api/catalog/1342/open"), self.client.post("/api/catalog/1342/open"),
            )
            self.assertEqual(first.status_code, 200, first.text)
            self.assertEqual(second.status_code, 200, second.text)
            book = first.json()
            self.assertTrue(book["unlocked"])
            self.assertGreater(book["total_lines"], 200)
            self.assertEqual(book["id"], second.json()["id"])
            self.assertEqual((await self.client.post("/api/library/open", json={"id": 1342})).json()["id"], book["id"])
        self.assertEqual(len(called), 4)
        self.assertEqual(len(list(self.books.glob("*.json"))), 1)
        path = f"/api/books/{book['id']}/lines"
        lines = await self.client.get(path, params={"start": 200, "count": 100})
        self.assertEqual(lines.json()["available"], book["total_lines"])
        self.assertEqual(lines.json()["lines"][-1]["text"], ending)
        opening = await self.client.get(path, params={"count": 1})
        self.assertNotIn("Gutenberg preamble", opening.json()["lines"][0]["text"])

        # In web mode the cookie owner cannot see a personal library's stored copy.
        with patch.dict(os.environ, {"TELLER_PERSONAL_MODE": "0"}):
            async with self.make_client(authenticated=False) as guest:
                self.assertEqual((await guest.get(path)).status_code, 404)

        response = await self.client.delete(f"/api/my/books/{book['id']}")
        self.assertEqual(response.json(), {"deleted": True})
        self.assertEqual((await self.client.get(path)).status_code, 404)
        self.assertEqual(list(self.books.glob("*.json")), [])

    async def test_classic_refuses_an_edition_without_public_domain_rights(self):
        async def read_asset(_client, url, _limit):
            self.assertTrue(url.endswith("/1342/pg1342.rdf"))
            return b"""<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:pg="http://www.gutenberg.org/2009/pgterms/" xmlns:dc="http://purl.org/dc/terms/">
                 <pg:ebook rdf:about="ebooks/1342"><dc:rights>Copyrighted.</dc:rights></pg:ebook>
                 </rdf:RDF>"""

        with patch.object(book_catalog, "_read_asset", read_asset):
            response = await self.client.post("/api/catalog/1342/open")
        self.assertEqual(response.status_code, 404)
        self.assertIn("public domain", response.json()["detail"])
        self.assertEqual(list(self.books.glob("*.json")), [])

    async def test_librivox_router_returns_ordered_human_manifest(self):
        projects = {
            "books": [{
                "id": "1480", "title": "Pride and Prejudice", "authors": [{"first_name": "Jane", "last_name": "Austen"}],
                "num_sections": "2", "sections": [
                    {"id": "2", "title": "Chapter 2", "section_number": "2", "playtime": "00:02:15",
                     "listen_url": "http://www.archive.org/download/test_item/chapter2.mp3"},
                    {"id": "1", "title": "Chapter 1", "section_number": "1", "playtime": "00:02:10",
                     "listen_url": "http://www.archive.org/download/test_item/chapter1.mp3",
                     "readers": [{"display_name": "Reader One"}]},
                ],
            }]
        }
        catalog = human_audio.CatalogClient()

        async def get(path, params, **_):
            self.assertEqual(path, "/api/feed/audiobooks/")
            if "id" in params:
                return projects if params["id"] == "1480" else None
            self.assertEqual(params["title"], "^Pride")
            return projects

        with patch.object(human_audio, "catalog", catalog), patch.object(catalog, "_get", get):
            search = await self.client.get("/api/catalog/human", params={"q": "Pride"})
            self.assertEqual(search.status_code, 200, search.text)
            self.assertEqual(search.json()["items"][0]["narration"], "human")
            response = await self.client.get("/api/catalog/human/1480")
            self.assertEqual(response.status_code, 200, response.text)
            book = response.json()
            self.assertEqual(book["rights"], "public_domain_us")
            self.assertEqual(book["duration_seconds"], 265)
            self.assertEqual([track["id"] for track in book["tracks"]], ["1", "2"])
            self.assertEqual(book["tracks"][0]["readers"], ["Reader One"])
            self.assertEqual(book["tracks"][0]["audio_url"], "https://archive.org/download/test_item/chapter1.mp3")
            missing = await self.client.get("/api/catalog/human/1490")
            self.assertEqual(missing.status_code, 404)
