---
id: touch-bar-001
scope: local mobile Touch Bar
status: in-progress
depends-on: []
---

## Objective

Deliver approved mobile UI with real local Mac capabilities, native Tools settings entry and authenticated LAN access, then open a PR. User explicitly authorized implementation and PR creation.

## Context

- docs/architecture/touch-bar.md (API and lifecycle source of truth)
- docs/ui/README.md
- docs/operations/build-release.md

## Path

- Sources/TouchBar*.swift, Sources/App.swift
- Resources/touch-bar.html, Resources/mvp-ui-prototype.html
- build.sh, Info.plist, dependency manifest/lock if necessary
- Tests/TouchBar*, relevant documentation

## Verification

Separate develop and verify agents. Compile both architectures, HTTP adversarial tests, provider tests, browser interactions, existing transport regression checks. Do not claim physical-phone or Intel runtime verification from a local build.
