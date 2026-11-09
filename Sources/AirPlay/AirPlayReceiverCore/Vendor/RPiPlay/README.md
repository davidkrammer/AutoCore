# RPiPlay (modified)

The AirPlay mirroring receiver in AutoCore is based on the `lib/` folder of
[RPiPlay](https://github.com/FD-/RPiPlay) by Florian Draschbacher and
contributors, at commit `64d0341` (2022-03-14). RPiPlay itself builds on
[shairplay](https://github.com/juhovh/shairplay) by Juho Vähä-Herttua,
playfair, and work by dsafa22.

## Licenses

- RPiPlay as a whole: GNU GPL v3.0 (see `LICENSE` at the root of AutoCore).
- Most files from shairplay and dsafa22: GNU LGPL v2.1 or later (see each
  file's header and `LICENSE-LGPL-2.1.txt` here).
- `lib/playfair/`: GNU GPL v3.0 (`lib/playfair/LICENSE.md`).
- `lib/llhttp/`: MIT (`lib/llhttp/LICENSE-MIT`).

## Changes in AutoCore (2026)

The code was changed to build on macOS inside an app, without OpenSSL,
libplist or Avahi:

- `crypto.c`, `pairing.c`, `pairing.h`: AES and SHA use Apple's
  CommonCrypto instead of OpenSSL; the Ed25519 and X25519 functions are
  implemented in Swift with CryptoKit (`AirPlayCrypto.swift`).
- `dnssd.mm`, `dnssd.h` (replace `dnssd.c`): Bonjour through Apple's dns_sd.
- `airplay_plist_support.mm`, `airplay_plist_support.h` (new): property
  lists through Foundation instead of libplist; `raop_handlers.h` uses them.
- `raop_rtp_mirror.c`: H.264 parameter sets are parsed by
  `AVCConfigurationParser` and handed to the app's VideoToolbox decoder.
- `raop.c`, `raop_ntp.c`, `raop_rtp.c`, `httpd.c`, `netutils.c` and their
  headers: the iPhone's IPv6 address keeps its interface scope, closing an
  auxiliary AirPlay connection no longer ends the running mirror, and the
  HTTP server starts and stops under a lock.
- `byteutils.c`, `global.h`, `stream.h`, `utils.h`: small build fixes for
  Apple's toolchain.
- The CMake files were removed; Xcode builds the sources.
