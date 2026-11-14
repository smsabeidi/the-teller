# The Teller

The Teller is a native iPhone audiobook studio. Import a public story link, select an EPUB, PDF, DOCX, or TXT file in Files, or paste a story. The backend casts the script, and the app plays a free opening with a speaker-by-speaker transcript. Open the Library to pick up where you left off. A bundled sample runs without a backend.

## Run on an iPhone simulator

Use Xcode 16 or newer with an installed iOS simulator, and Python 3.12 or newer. The app's minimum OS is iOS 17.4.

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m uvicorn server:app --host 127.0.0.1 --port 8000
```

Open `ios/TheTeller.xcodeproj` and run the **TheTeller** scheme. For a physical iPhone, select a signing team, run the backend with `--host 0.0.0.0` on a trusted development network, and set the scheme's **Run → Arguments → Environment Variables** value `TELLER_API_BASE_URL` to your Mac's LAN address and port. When building a release, set the target's `TELLER_API_BASE_URL` build setting to your deployed HTTPS origin.

Without provider keys, the device reads the script with its installed voices. To use server audio, the backend supports the provider settings in `.env.example`. The guest MVP lets users continue to the full book for free when web billing is disabled. Keep that setting for local development.

## Verify

With the backend running on port 8000, select an installed simulator and run:

```sh
xcodebuild test -project ios/TheTeller.xcodeproj -scheme TheTeller \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO
```

The [iOS PRD](PRD-iOS.md) covers the MVP and later releases. The backend also serves the web studio at [localhost](http://127.0.0.1:8000/). See [deployment notes](DEPLOY.md) for its server configuration.
