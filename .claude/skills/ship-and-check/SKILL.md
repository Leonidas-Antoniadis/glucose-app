---
name: ship-and-check
description: Commit, push and verify a change in the glucose app through GitHub Actions. Use after any code change in this repo, since Swift cannot be compiled on this Windows PC.
---

# Ship and check

This repo has no local Swift toolchain. GitHub Actions is the only compiler.

1. Commit with a plain message. Never add a Claude co-author line.
   Commits are SSH-signed automatically (repo-local git config).
2. Push: `git push origin main`.
3. Find the runs (gh lives at `D:/Tools/gh/bin/gh.exe`):
   ```bash
   /d/Tools/gh/bin/gh.exe run list --limit 4
   ```
   - **Core tests** (`core-tests.yml`) run on every push: `swift test` on Linux for `Packages/GlucoseCore`.
   - **iOS build** (`ios-build.yml`) runs when `App/**` or `Packages/**` change: XcodeGen + xcodebuild on macOS, uploads the unsigned IPA.
4. Wait in the background, then read only what matters:
   ```bash
   gh run watch <id> --exit-status --interval 15 >/dev/null; echo $?
   gh run view <id> --log | grep -E "error:|failed|Executed [0-9]+ tests"
   gh run view <id> --log-failed | grep -E "error:"
   ```
5. Fix any compile error or test failure and push again as a separate commit, so every step is on GitHub.

Gotchas:
- Linux Foundation lacks some Apple APIs: keep `Packages/GlucoseCore` free of UIKit, CoreBluetooth, CoreNFC, CryptoKit and os.
- App code is Swift 5 language mode; calling `@MainActor` code from delegate callbacks needs `MainActor.assumeIsolated`.
- The Xcode project is generated from `App/project.yml`; never commit `.xcodeproj`.
