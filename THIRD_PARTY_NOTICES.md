# Third-party software

AutoCore is licensed under the GNU General Public License v3.0 (`LICENSE`).
It contains or downloads the following software.

| Component | Where | License | Upstream |
| --- | --- | --- | --- |
| RPiPlay (modified) | `Sources/AirPlay/AirPlayReceiverCore/Vendor/RPiPlay` | GPL-3.0 | https://github.com/FD-/RPiPlay |
| shairplay parts of RPiPlay | same folder, see file headers | LGPL-2.1-or-later | https://github.com/juhovh/shairplay |
| playfair | `…/RPiPlay/lib/playfair` | GPL-3.0 | via RPiPlay |
| llhttp | `…/RPiPlay/lib/llhttp` | MIT | https://github.com/nodejs/llhttp |
| WebDriverAgent | downloaded and built by `scripts/build-wda.sh`, not in this repository | BSD-3-Clause (`Resources/WebDriverAgent-LICENSE.txt`) | https://github.com/appium/WebDriverAgent |

What AutoCore changed in RPiPlay is listed in
`Sources/AirPlay/AirPlayReceiverCore/Vendor/RPiPlay/README.md`.

AirPlay, iPhone, Mac and Xcode are trademarks of Apple Inc. AutoCore is not
affiliated with or endorsed by Apple.
