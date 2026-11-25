# macOS Notes

- Playwright: when Google Chrome is installed, launch it with `channel: 'chrome'`
  (`chromium.launch({ channel: 'chrome' })` / `launchPersistentContext(dir, { channel: 'chrome' })`)
  instead of the bundled "Google Chrome for Testing", which triggers a macOS Local Network
  permission prompt on every launch.
- A force-killed Chrome on macOS leaves a ~1.4 GB `com.google.Chrome.code_sign_clone` copy of
  the app under `$TMPDIR/../X/`, and these pile up; this is why browsers must always be
  closed cleanly.
