# Deploy The Teller

## Private server and iPhone

Run the native app against a single personal server. The server key grants access to one library and works across installs. The app stores it in iOS Keychain. The server software and on-device voices work without paid provider keys.

1. From the repository, create the Python environment and initialize the server.

   ```sh
   python3 -m venv .venv
   .venv/bin/python -m pip install -r requirements.txt
   ./scripts/personal-server.sh init
   ./scripts/personal-server.sh start
   ```

   The initializer creates a gitignored `.env` readable only by your user. If one already exists, preserve your settings and set `TELLER_ACCESS_KEY` to a new random URL-safe key of at least 32 characters. Save the key in your password manager. The server listens on `127.0.0.1:8016` and runs while the process and Mac are up.

2. Connect the Mac and iPhone to the same Tailscale tailnet. On the Mac, run `tailscale serve --bg 8016` and copy the HTTPS origin it prints. The HTTPS origin must serve The Teller at its root. A private reverse proxy you already operate can also forward to `127.0.0.1:8016`. [Tailscale Serve documentation](https://tailscale.com/docs/reference/tailscale-cli/serve)

3. Open `ios/TheTeller.xcodeproj` in Xcode. Add your Apple Account, select your team under **Signing & Capabilities**, choose your unlocked iPhone as the destination, and run **TheTeller**. If Xcode prompts for device trust or Developer Mode, follow the on-device instructions. Apple’s free Personal Team builds need renewed provisioning after seven days. [Run on a device](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) · [Apple developer accounts](https://developer.apple.com/help/account/basics/about-your-developer-account)

4. In The Teller, open **Settings**, enter the HTTPS origin and `TELLER_ACCESS_KEY`, then tap **Test and save**. Open a classic under **Discover**, or choose **Human narration** to stream a LibriVox recording. Personal mode starts its own library. Existing guest books stay associated with their guest session.

### Expand and maintain the catalog

Discover starts with 12 curated Project Gutenberg editions. To enable broader search, download the official weekly catalog into the persistent data directory and set `GUTENBERG_CATALOG_PATH` to its absolute path in `.env`. The server also accepts a gzip CSV and reloads the index when the file changes. Search records are checked against the source edition's rights before any text is fetched. [Project Gutenberg offline catalogs](https://www.gutenberg.org/ebooks/offline_catalogs.html)

```sh
mkdir -p data
curl -fL https://www.gutenberg.org/cache/epub/feeds/pg_catalog.csv -o data/pg_catalog.csv.new
mv data/pg_catalog.csv.new data/pg_catalog.csv
```

Stop the server before taking a snapshot. In the repository, run `python3 scripts/backup-personal.py /absolute/path/teller-backup.tar.gz` (add `--data /path/to/data` if you configured a different data directory). To restore, stop the server, move the current data directory aside, and extract the trusted backup to a staging directory. Move the extracted `data` directory back to the configured data location, then start the server. Keep your `.env` or a copy of its settings separately in your password manager. Rotate the server key by stopping the service, changing `TELLER_ACCESS_KEY`, restarting, and reconnecting the app in **Settings**.

## Web studio

Build the Docker image in this folder and run one instance with a persistent volume at `/app/data`. It holds the library and account database, transcripts, generated audio, and exports. The app keeps active casting and export progress in memory. A process restart interrupts those jobs, and the player can start them again.

To run with Docker Compose, copy `.env.example` to `.env` before starting the service.

```sh
cp .env.example .env
docker compose up --build
```

For a public app, set `PUBLIC_BASE_URL` to the HTTPS origin in the browser. If using a reverse proxy to report client IPs for rate limiting, configure Uvicorn's `FORWARDED_ALLOW_IPS` for the trusted proxy addresses only. Set any provider credentials through your host's secrets settings.

## Sign-in

Set the credentials for any enabled sign-in method.

- Google OAuth redirect URI is `PUBLIC_BASE_URL/api/auth/google/callback`.
- Discord OAuth redirect URI is `PUBLIC_BASE_URL/api/auth/discord/callback`.
- Email sign-in uses `SMTP_HOST` and `SMTP_FROM` and supports credentials from `SMTP_USERNAME` and `SMTP_PASSWORD`. A sign-in link expires after 15 minutes and must be confirmed in the browser that requested it.

The app associates guest imports with the account when the user signs in. Without configured sign-in providers, the local guest library remains available in the same browser.

## Stripe

Configure your own prices in Stripe. Set `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, and the IDs for the one-time purchase and any subscriptions you offer. A new book credit allowance becomes available for each paid billing period. Credits expire at the end of that period. Enable Stripe's customer portal to expose billing management in the account dialog.

Register `PUBLIC_BASE_URL/api/stripe/webhook` with these events.

- `checkout.session.completed`
- `checkout.session.async_payment_succeeded`
- `checkout.session.async_payment_failed`
- `checkout.session.expired`
- `invoice.paid`
- `customer.subscription.deleted`

Start with Stripe test prices, keys, and a test webhook. Without a configured checkout, users can open the full story from the free preview.
