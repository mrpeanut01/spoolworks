import SpoolworksUI

// Thin entry point. Everything lives in SpoolworksUI so the UI state machine — auto-read/auto-write
// arming, the draft cascade, reader busy accounting — is reachable from tests. SwiftPM refuses to
// let one target depend on an executable, so the app cannot be both the scene graph and `@main`.
SpoolworksApp.main()
