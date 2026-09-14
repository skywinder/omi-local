# Starting omiloc

For containers on Mac CPU or Linux/WSL2 NVIDIA, see [Docker](DOCKER.md).

You need an Apple Silicon Mac, macOS 14 or later, Xcode with Swift 6.0 or later,
and an [ngrok account](https://dashboard.ngrok.com).
Recording requires a CV1 and the [iPhone app](LOCAL_SETUP.md).
The first installation needs internet access.

## Installation

Get the project and start setup in Terminal:

```bash
git clone https://github.com/vquaron/omi-local.git omiloc
cd omiloc
./start.command
```

If macOS offers to install developer tools for Git, complete that installation
and repeat the command. If you already have the project, start with `start.command`.

## First launch

For setup without prompts, use a private [`.env`](NGROK.md#noninteractive-setup-env).
`bash scripts/local-mac.sh init-env` creates it without printing secrets.

1. Double-click `start.command`, or run `./start.command` in Terminal from the
   project directory.
2. The script installs and checks missing dependencies. If a check fails, it
   explains what to fix; Enter retries, and `q` exits setup.
   It then prepares WhisperKit for final transcripts and Parakeet for live text:
   it compiles workers, downloads pinned models, and checks them on synthetic speech.
   You need at least 4 GiB of free space; initial preparation may take several minutes.
   If model preparation stops, fix the reported cause and run `start.command` again.
   Then enter the HTTPS address and authtoken from your ngrok dashboard.
   The authtoken input is hidden; press Enter if it is already configured.
   You can also supply both values in a [private `.env`](NGROK.md#supplying-the-address-and-token-through-env).
3. In the Omi iPhone app, open **Local Mac**, enter the **domain and key shown in
   the boxed output**, and check the connection.

The app key is different from the ngrok authtoken and is shown once: save it.
This applies to the interactive wizard; with `.env`, the key is stored in that file.
Subsequent launches reuse the saved settings. The final boxed output shows the
`omiloc` command and library address; you can close Terminal after startup.
Repeated startup preserves the running library, tunnel, and local STT services.
Install the iPhone app separately. A fresh setup enables both transcription paths;
existing engine choices and explicit disabled settings are preserved.
See [final transcription](LOCAL_STT.md) and [live preview](LIVE_PREVIEW.md).

## Usage

Run `start.command` to record. Connect the CV1 in the app, press the CV1 button once
to start recording, and press it again to finish. Mute temporarily silences audio
without finishing the file. The Mac must remain running and awake.

To browse your archive, run **`omiloc`** from any directory in Terminal.
It opens the [audio library](http://127.0.0.1:20001/), accessible only on this Mac.
Do not open `index.html` directly.

Select a recording, start the player, or click a phrase to seek to its timestamp.
You can change playback speed and search by date, source, or transcript prefix.
New recordings and completed transcripts appear automatically.

**Delete recording** removes the audio, transcript, and linked conversation after
confirmation. Start the services with `start.command` and wait for transcription
to finish before deleting. For duplicate audio, the shared transcript remains
until the last copy is deleted. Then return to the iPhone conversation list and
pull down to refresh. If the last deleted recording remains, update the app.

## Troubleshooting

Mac setup output is saved in `.local/install.log`.
Run the following commands from the project directory.

- `omiloc` is not found: run `./omiloc --install`, then open a new Terminal window.
- `start.command` does not open: run `bash start.command`.
- Setup was interrupted: run `start.command` again to retry installation.
  To repair dependencies manually: `bash scripts/install-local-mac.sh`.
- Check models and observed live/final readiness: `./start.command --check`.
- Check tools, signing, and the phone: `./start.command --iphone-check`.
- Stop services while preserving data: `bash scripts/local-mac.sh down`.
- Replace a lost key: after stopping, run `bash scripts/local-mac.sh rotate-key`,
  start `start.command`, and enter the new key on the iPhone.
- The phone cannot connect: see [connection setup](NGROK.md).
- The phone connects but text is unavailable: check the Live Transcript / Transcript
  message during connection and run `./start.command --check` on the Mac. Models run on the Mac.
- An update reports that the backend uses earlier settings: finish recording and
  processing, run `bash scripts/local-mac.sh down`, then `./start.command`.

After restarting the Mac, run `start.command` to record or `omiloc` to listen.
See [current limitations](TEMPORARY_DISABLED_FEATURES.md).
