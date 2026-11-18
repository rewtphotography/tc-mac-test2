# TrainCull for Mac

A lean, folder-based replacement for Adobe Bridge with raw-first editing, for one photographer
(the owner). Read `docs/NOTES.md` before changing anything: it holds the owner's decisions,
what is built, and what is next.

## Working with the owner

- **Make sensible default choices.** State the default in a line, mention alternatives
  briefly, and move on. Do not answer a decision with a batch of follow-up questions.
- **Keep replies short.** Save side effects and caveats to `docs/NOTES.md` ("Known caveats")
  instead of listing them in replies; raise one only if it would cause real damage or cannot
  be undone.
- **Build, then show the result.** Do not wait for a go-ahead that has effectively been given.
- **With every new release, give the direct download link** (below) and the link to that
  release's page. The owner installs from the downloaded file and does nothing else.
- **Log freely while in alpha.** New behaviour writes what it did, how long it took and any
  error to the diagnostics log (`Log.note`). Memory use is reported in plain language.
- The owner does not use the terminal or Xcode and has no Apple Developer account. Explain
  anything they must do as plain steps in an app's own interface.
- Before building from any spec in `docs/specs/` (or one the owner pastes in), audit it against
  the code, `docs/NOTES.md` and the rules here, and tell the owner about any conflict first.
  Specs are written by other sessions that have not seen this code. Record in the notes what
  was adopted, changed or left out.
- Never commit photos, raw files, sidecars, logs or signing material. Tests build their files
  from synthetic bytes in code.
- Verify your own work: check the automated build and read its logs before reporting.

## How it is built and delivered

- A Swift package. `Sources/TraincullCore` has no UI and is tested on Linux and Mac
  (`swift test`). `Sources/TrainCull` is the Mac app (SwiftUI and AppKit) and builds only on
  a Mac.
- Every push builds the app on GitHub (`.github/workflows/build.yml`), runs the tests and
  starts the app on made-up frames. Only pushes to `main` and version tags publish
  `TrainCull.dmg` under Releases as the latest release; other branches never do. The version
  is in `packaging/VERSION` (0.2.0); a release is tagged `v0.2.0-alpha.N` and titled
  "TrainCull 0.2.0 alpha N", N following on from the last release of that version. The old
  `alpha-N` tags (alphas 4 to 23) belong to 0.1.0; never reuse that form.
- Masking (alphas 7–23) is archived on branch `archive/masking`, tag `masking-final`. It is
  not on `main`.
- The newest build is always at
  `https://github.com/<owner>/<repository>/releases/latest/download/TrainCull.dmg`.
- Pictures of the app starting, in the single and side-by-side views and in Edit mode, are kept
  with each build as the `launch-screenshot` artifact, with the app's own log (`.log` and
  `.jsonl`); look at them. The built app is kept as the `TrainCull` artifact for 14 days.
- `swift test` needs no Mac for `TraincullCore`. `Tests/TrainCullTests` runs on the Mac build only.
- Bundle ID `com.traincull`. No sandbox. The app never uses the network; the build fails if
  networking code is linked in.
