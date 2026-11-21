# Alpha debug tools (alpha only)

The Debug menu: **Run Test Script…**, **Export Debug Package**, **Reset Manual Export Counter**.
Output goes to `~/Pictures/TrainCull Debug/`, one new folder per run. Every file here is
compiled only when `TC_ALPHA_DEBUG` is defined (Package.swift: on unless built with
`TC_ALPHA_DEBUG=0`). The app does not depend on anything here.

To remove the tools for good:
1. Delete this folder and `Tests/TrainCullTests/AlphaDebugTests.swift`.
2. In `Package.swift`, delete the `alphaDebug` / `appSettings` lines and use
   `[.swiftLanguageMode(.v5)]` for the TrainCull and TrainCullTests targets again.
3. In `TrainCullApp.swift`, delete the three lines from `#if TC_ALPHA_DEBUG` to `#endif`.
4. In `.github/workflows/build.yml`, delete the steps marked B1 and B3, B12, B13, and the
   launch-check lines that use `-TCDebug…`.

The small read-only helpers the tools use elsewhere (`Session.settledPreview`,
`Session.singleView`, `HeroNSView.visibleSpaceRect`, `Export.render16`,
`Imaging.developedReading`, `RenderCache.peek`) are general and can stay.
