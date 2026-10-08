---
id: all-features-test-001
scope: Review open PRs and build an integrated local candidate
status: done
depends-on: []
---

# Integrated test candidate

## objective

Review current open PR heads, integrate all approved features into a separate local test branch, fix blocking findings, and produce arm64/x86_64 packages. User explicitly includes PR #4 mobile Touch Bar. Do not merge GitHub PRs or publish a release as part of this task.

## context

- docs/INDEX.md
- docs/architecture/media.md
- docs/architecture/protocol.md
- docs/ui/README.md
- docs/operations/build-release.md
- PR #4 docs/architecture/touch-bar.md

## sources

- PR #2: 8f68c2264116e893f3eb58d17d2f6a9b59a3b554 (captured cursor already integrated locally)
- PR #3: f86b8798a2bc58a3f8680f3e1dd208797faf37b4
- PR #4: d20853d7da40cd17d38ba6888855a2a6a264af5b
- PR #5: 98eebb3b06f17bc6b2b58b63a1d0da66e4c712a1

## path

Integrate PR #4 into the current PR #5 baseline, resolving App.swift, Info.plist, runtime HTML and documentation conflicts without discarding either feature. Preserve the existing native-panel catalog/assets and captured cursor. Update version to 0.7.2 build21 (protocol4 unchanged unless review proves a wire change necessary). Record review findings and precise validation limits.

## verification

Independent review of PR #4 source and final combined state. Run all meaningful existing transport, video, demo, Touch Bar HTTP/provider/browser checks; build both architectures and verify ZIP signatures/versions/assets. Confirm actual app ownership starts/stops Touch Bar, native bridge navigation works, passive polling does not request privileges, and endpoint actions remain bounded and authenticated. Retain local version cache fix and all five mode choices. Exact BGRA reconstruction, captured cursor, panel mapping and per-device selection must remain intact. No real dual-Mac/iPhone performance claims without hardware evidence.

## UI

```text
Tools                      Device output
  Configuration checks       Mode [SDR / Fidelity / RGB / Demo 1 / Demo 2]
  Touch Bar                 Touch Bar settings
                              Enable / Pair / Widgets / Permissions
```

Both feature sets must be reachable in the same application, with mutually exclusive sidebar selection.

## Implementation handoff

PR #4 was merged locally with conflicts resolved by preserving both Touch Bar page packaging and the panel catalog, and both UI documentation sections. PR #2 captured-cursor behavior already exists on this branch; no duplicate cursor merge was needed. PR #3 / #5 display modes, pixel reconstruction, cache-version probe and geometry remain unchanged. PR #4 blocking findings are fixed with regression tests. Version is 0.7.2 build 21, protocol 4. Local checks and both architecture packages passed; independent final review remains required. No GitHub merge, push or release was performed.

## Final verification

Independent review passed in 4278af9, recorded in ../reviews/all-features-test-001-001.md. Both packages were extracted and verified against the integrated source. Local review/integration/package delivery is complete; physical dual-Mac, iPhone Safari and Intel runtime acceptance remains with the user. GitHub PRs remain open.
