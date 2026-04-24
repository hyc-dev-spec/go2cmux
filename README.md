# go2cmux

English | [简体中文](README.zh-CN.md)

`go2cmux` is a tiny macOS helper app for opening the current Finder folder in [`cmux`](https://github.com/manaflow-ai/cmux).

It is designed for the same workflow as tools like Go2Shell: add the app to the Finder toolbar, click it, and jump straight from the current Finder location into your terminal app. The difference is that this project targets `cmux`.

## What It Does

When you click `go2cmux` from the Finder toolbar, it:

1. Reads the current folder from Finder
2. Launches `cmux` if needed
3. Opens that folder as a new `cmux` workspace

The current implementation is intentionally small and focused. It does not modify `cmux`, and it does not depend on a locally built development copy of `cmux`.

## Why This Exists

`cmux` already supports opening folders, but older Finder helpers such as Go2Shell typically only know how to open classic terminal apps like Terminal.app or iTerm. `go2cmux` fills that gap with a dedicated Finder launcher for `cmux`.

## Requirements

- macOS
- A locally installed copy of `cmux`
- Xcode if you want to build from source (`build.sh` uses `actool` to compile the light/dark app icon asset catalog)

For runtime, `go2cmux` looks for `cmux.app` in this order:

1. The app registered with bundle identifier `com.cmuxterm.app`
2. `/Applications/cmux.app`
3. `~/Applications/cmux.app`

## Permissions

`go2cmux` uses Apple Events / automation to talk to:

- Finder, to read the current folder
- `cmux`, to create a workspace

The first time you use it, macOS may ask you to allow `go2cmux` to control Finder and `cmux`. If access is denied, the app shows a targeted error message that tells you which permission is missing.

## Build

You can build the app in either of these ways:

1. Open [go2cmux.xcodeproj](/Users/yandaoyang/tool/go2cmux/go2cmux.xcodeproj/project.pbxproj) in Xcode and build the `go2cmux` target
2. Run the build script from Terminal

The repository includes a build script that creates an ad-hoc signed app bundle:

```bash
./scripts/build.sh
```

Build output:

```text
build/go2cmux.app
```

The script:

- copies `Resources/Info.plist` into the app bundle
- refreshes the light/dark `AppIcon.appiconset` from the two 1024x1024 master PNGs
- compiles `Sources/go2cmux/AppDelegate.swift` and `Sources/go2cmux/main.swift` with `swiftc`
- compiles the asset catalog with `actool`
- signs the resulting `.app` with ad-hoc `codesign`

## Use

1. Build the app or download a prebuilt copy
2. Drag `go2cmux.app` into the Finder toolbar
3. Open any folder in Finder
4. Click the toolbar button

Expected behavior:

- If `cmux` is already running, `go2cmux` adds a workspace for the current Finder folder
- If `cmux` is not running, `go2cmux` launches it first and then opens the folder

## Project Layout

- `Sources/go2cmux/AppDelegate.swift`: app logic
- `Sources/go2cmux/main.swift`: app entry point
- `go2cmux.xcodeproj`: minimal Xcode project
- `Assets.xcassets/AppIcon.appiconset`: compiled app icon asset catalog
- `Resources/Info.plist`: app bundle metadata
- `scripts/build.sh`: local build script
- `scripts/update_appiconset.sh`: syncs the icon set from the light/dark master PNGs

## Known Limitations

- This is a macOS-only project
- It depends on `cmux` being installed locally
- It currently targets one Finder folder at a time
- The generated `.app` in `build/` is a build artifact and is not tracked in git

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
