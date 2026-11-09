# Contributing to AutoCore

Thanks for helping. A few things make it easier to take your change.

## Before you start

- For a larger change, open an issue first, so we can agree on the approach.
- AutoCore is the generic part: mirroring, touch control, text recognition,
  windows and the Remote. Features for one particular app belong in that
  app's `Tools`, not here.

## Building

Follow "Getting started" in the README. `xcodegen generate` recreates
`AutoCore.xcodeproj` from `project.yml`; don't commit the generated project.
Run the tests with the **AutoCore** scheme (⌘U) or:

```sh
xcodebuild -project AutoCore.xcodeproj -scheme AutoCore -destination 'platform=macOS' test
```

`--ui-demo <scenario>` starts the app with sample data, without AirPlay or
an iPhone (scenarios include `idle`, `running`, `read`, `menu`, `remote`).
Add `--ui-demo-image <png>` to show a picture as the mirror.

## Style

- Swift, SwiftUI and AppKit; follow the style of the file you change.
- User-facing text is short and plain. Add the German translation to
  `Resources/de.lproj/Localizable.strings` (or `Demo/de.lproj` for the demo).
- Keep changes focused: one topic per pull request, with tests where it fits.
- Don't commit signing settings (`Config/Local.xcconfig`) or the
  WebDriverAgent archives.

## License

By contributing, you agree that your contribution is licensed under the
GNU General Public License v3.0, like the rest of AutoCore.
