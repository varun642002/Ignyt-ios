# IGNYT — iOS

The iOS build of IGNYT. Android lives separately in
[Ignyt-testing-](https://github.com/varun642002/Ignyt-testing-), and so does the app itself.

## Why the app is not in this repo

`www/` is the entire application — UI, exercise library, food database, images — and both
platforms need it. In one recent week 568 files under `www/` changed. A second copy would
spend every one of those changes drifting out of step, which has already happened once on
this project with a duplicated website directory.

So the web layer stays in one place and is mounted here as a submodule:

```
Ignyt-ios/
  ignyt-app/          submodule -> Ignyt-testing- (the app; only www/ is used)
  ios/                the Xcode project and the Swift plugins
  capacitor.config.json   webDir points at ignyt-app/www
  codemagic.yaml      the build
```

The platforms are otherwise fully separate: separate repos, separate CI, separate issues.
Nothing done here can change Android's behaviour.

## Working on it

There is no Mac on this project. Every build runs on Codemagic's cloud Macs; an iPhone is a
test device, not a build machine. Do not expect to open Xcode — anything Xcode would
normally do by ticking a box has to be written into this repo by hand, which is why
`App.entitlements` and `CODE_SIGN_ENTITLEMENTS` are committed rather than left as a
capability to enable.

Clone with the submodule, or `ignyt-app/` will be empty and the app will build to a blank
screen:

```bash
git clone --recurse-submodules https://github.com/varun642002/Ignyt-ios.git
```

### One Windows quirk to know about

Running `npx cap sync ios` on Windows rewrites `ios/App/CapApp-SPM/Package.swift` with
backslash path separators:

```swift
.package(name: "CapacitorApp", path: "..\..\..\node_modules\@capacitor\app")
```

Swift Package Manager reads that as a single filename, so a Mac fails to resolve the package
before compiling anything — with an error that says nothing about Windows. Forward slashes
work on both platforms; normalise it before committing.

CI is unaffected either way, because it runs `cap sync ios` on macOS and regenerates the file
correctly. This only bites a commit made from Windows.

To pick up app changes, move the submodule pointer deliberately and commit it:

```bash
git -C ignyt-app fetch origin
git -C ignyt-app checkout <commit-or-branch>
git add ignyt-app && git commit -m "Update the app to <commit>"
```

That step is manual on purpose. iOS updates its web layer when someone decides to, rather
than inheriting whatever Android happened to push.

## Build

Two Codemagic workflows, in this order:

| Workflow | Signing | Needs an Apple account | Use |
| --- | --- | --- | --- |
| `ios-compile-check` | none | no | Compile the Swift and read the errors. Free. |
| `ios-testflight` | managed | yes, $99/yr | Ship a build to a phone. |

Exhaust the first before touching the second — paying Apple to discover a syntax error is a
poor trade.

## State of the port

The HealthKit plugin compiles. It has never run.

`ios/App/App/HealthConnectPlugin.swift` implements all 29 methods of the Android
`HealthConnectPlugin`, registered under the same JS name so the web layer needs no changes.
Compiling proves the syntax, the API signatures and the async/await usage. It does not prove
Capacitor finds the plugin at launch — that resolves at runtime — nor that permissions,
reads or writes behave.

Two differences from Android are deliberate and documented in the source, not bugs:

- iOS never reveals whether a **read** permission was granted, so `getPermissionStatus`
  reports what it can and sets `readAuthorizationIsUnknowable`.
- `kcalPerDay` carries HealthKit's cumulative basal burn, not Health Connect's kcal/day rate.

### Not yet ported

Four native plugins are Android-only Kotlin with no Swift counterpart, so these features are
inert on iOS:

- **Auth** — and this one is blocking. Sign-in gates the whole app, so iOS currently cannot
  get past its first screen. Fixing it means either a Swift `AuthPlugin` on the Firebase iOS
  SDK, or the Firebase **Web** SDK inside the webview, which needs no native code.
- Notifications and reminders
- Cloud sync
- Native share
