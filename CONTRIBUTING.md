# Contributing to OpenMacBattery

Thanks for considering a contribution! This is a small project — every PR matters.

## Quick start

```bash
git clone https://github.com/MuratDugan/openmacbattery.git
cd openmacbattery
swift build -c release --arch arm64
swift test
./scripts/make-app.sh   # builds .app into ./build/
```

## Code

- **Language**: Swift 5.9+
- **Style**: defaults — no SwiftLint config yet, just match the existing code.
- **Architecture**: three SPM targets — `OpenMacBatteryCore` (data + sampler), `OpenMacBattery` (CLI), `OpenMacBatteryApp` (SwiftUI GUI).
- **Tests**: XCTest under `Tests/OpenMacBatteryCoreTests/`. Run with `swift test`.

## Translations

UI is localized in 8 languages under `Sources/OpenMacBatteryApp/Resources/{lang}.lproj/Localizable.strings`. The non-English translations are **machine-quality** as a starting point — native-speaker reviews are highly welcome.

To improve a translation:

1. Pick the file (e.g. `de.lproj/Localizable.strings`).
2. Edit the value (right side of `=`); never the key (left side).
3. **Preserve format specifiers** — `%lld`, `%@`, `%1$@`, `%2$lld` — and `%%` for literal `%`.
4. Submit a PR. One language per PR keeps reviews simple.

To add a new language:

1. Copy `en.lproj/` to `xx.lproj/` (e.g. `it.lproj/` for Italian).
2. Translate the values.
3. Add `xx` to `CFBundleLocalizations` in `scripts/make-app.sh`.
4. Add it to `AppLanguages.supported` in `Sources/OpenMacBatteryApp/LanguageMenu.swift`.

## Bugs / feature requests

Open an issue. For bugs, include:

- macOS version (`sw_vers`)
- Mac model (`sysctl -n hw.model`)
- A snippet from `~/Library/Logs/openmacbattery.error.log`
- What you expected vs. what happened

## Before opening a PR

- `swift build -c release --arch arm64` — clean build
- `swift test` — all green
- `./scripts/make-app.sh && open build/OpenMacBattery.app` — manual smoke test
- Git history: squash WIP commits, write a clear commit message

## License

By contributing, you agree your contribution is licensed under [AGPL-3.0](LICENSE).
