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
- The owner does not use the terminal or Xcode and has no Apple Developer account. Explain
  anything they must do as plain steps in an app's own interface.
- Never commit photos, raw files, sidecars, logs or signing material. Tests build their files
  from synthetic bytes in code.
- Verify your own work: check the automated build and read its logs before reporting.

## How it is built and delivered

- A Swift package. `Sources/TraincullCore` has no UI and is tested on Linux and Mac
  (`swift test`). `Sources/TrainCull` is the Mac app (SwiftUI and AppKit) and builds only on
  a Mac.
- Every push builds the app on GitHub (`.github/workflows/build.yml`), checks that it starts,
  and publishes it under Releases as a pre-release. The owner downloads the zip from there.
  A screenshot of the app starting is kept with each build as the `launch-screenshot`
  artifact; look at it.
- Bundle ID `com.traincull`. No sandbox. The app never uses the network; the build fails if
  networking code is linked in.
