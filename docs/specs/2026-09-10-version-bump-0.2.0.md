# Version bump to 0.2.0

**Goal:** Update Beanvan's marketing version from `0.1.4` to `0.2.0`.

**Approach:** Change `CFBundleShortVersionString` in `Support/Info.plist`. Keep
`CFBundleVersion` unchanged because the release workflow supplies the build
number independently.

**Out of scope:** No application behavior, dependency, release workflow, or
build-number changes.

**Success criteria:** `Support/Info.plist` reports version `0.2.0`, the full
Swift test suite passes, and the change is submitted in a PR targeting `main`.
