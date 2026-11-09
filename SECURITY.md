# Security

AutoCore controls iPhones and opens network services on your Mac (an AirPlay
receiver and, when enabled, the Remote server), so security problems matter.

## Reporting a vulnerability

Please report it privately through GitHub: on this repository's **Security**
tab, choose **Report a vulnerability**. Please don't open a public issue for
it. You will get an answer as soon as possible.

## What AutoCore does on the network

- **AirPlay receiver:** visible on the local network while a window is open,
  so iPhones can mirror to it.
- **Touch control:** HTTP to WebDriverAgent on your own iPhones (port 8100).
- **Remote server:** a Bonjour service on the local network, only while
  "Allow … Remote on this Wi‑Fi" is on. A Remote needs a one-time pairing
  with matching 6-digit codes and an OK on the Mac. After that each
  connection uses a fresh X25519 key agreement mixed with the pairing key,
  and every message is sealed with ChaCha20-Poly1305 and numbered against
  replay. Pairing keys are stored in the Mac's Application Support folder
  and the iPhone's Keychain; remove a paired iPhone in the Remote settings.

AutoCore has no accounts, no server of its own and no analytics.
