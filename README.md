# The Teller

The Teller is a native iPhone audiobook studio. Import a public story link, select an EPUB, PDF, DOCX, or TXT file, or paste a story. The app casts your text and plays it with a speaker-by-speaker transcript. In Discover, open Project Gutenberg classics for a Teller rendition or stream human-read recordings from LibriVox. Jump to a line or chapter, adjust playback speed, and pick up from Continue Listening in the Library. Three bundled samples play without a server.

## Use it on your iPhone

Follow the [personal deployment guide](DEPLOY.md) to create your private server key, connect your iPhone over HTTPS, and install the app with Xcode. Personal imports open the entire book and stay in your private library. Server voice providers are optional.

## Run on an iPhone simulator

Use Xcode 16 or newer with an installed iOS simulator, and Python 3.12 or newer. The app's minimum OS is iOS 17.4.

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
TELLER_PERSONAL_MODE=0 python -m uvicorn server:app --host 127.0.0.1 --port 8000
```

Open `ios/TheTeller.xcodeproj` and run the **TheTeller** scheme. The Debug build uses port 8000 unless you saved a connection in the app. To try personal mode in Simulator, run the private server on port 8016 and enter `http://127.0.0.1:8016` with its key in **Settings**. The Debug build accepts loopback HTTP. Release connections use HTTPS.

Without provider keys, the device reads the script with its installed voices. To use server audio, the backend supports the provider settings in `.env.example`. The guest MVP lets users continue to the full book for free when web billing is disabled. Keep that setting for local development.

## Verify

With the backend running on port 8000, select an installed simulator and run:

```sh
xcodebuild test -project ios/TheTeller.xcodeproj -scheme TheTeller \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO
python -m unittest discover -s tests -v
```

The [iOS PRD](PRD-iOS.md) covers the MVP and later releases. The [book API research](BOOK-API-RESEARCH.md) covers service capabilities, terms, and integration tradeoffs. Guest development mode also serves the [web studio](http://127.0.0.1:8000/).
