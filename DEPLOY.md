# Deploy VoiceEmo Studio

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
