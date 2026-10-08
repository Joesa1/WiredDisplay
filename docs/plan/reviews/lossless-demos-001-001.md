# Independent review: lossless-demos-001

- Reviewed commit: `86eada1a9f7a2926b023e6203433eb46034dc2b9`
- Date: 2026-10-08
- Verdict: PASS for draft PR and local comparison packages. No blocking correctness findings identified. Dual-Mac performance acceptance remains pending.

## Review evidence

- Dimension validation precedes size arithmetic and allocation. Region coordinates use subtraction bounds; maximum negotiated geometry keeps multiplication within Int and the 64 MiB wire limit.
- LZ4 decoding requires stream end, complete input consumption and exactly the advertised output size. The extra destination byte detects over-expansion. Invalid ancestry, empty/incomplete keyframes, malformed regions, unknown compression and incorrect payload sizes are rejected.
- Demo 1 compares against the last transmitted packed frame. Skipping capture callbacks cannot lose intermediate changes. TCP packet order preserves delta ancestry; all deltas reconstruct before the presentation layer may skip an old image.
- Data copy-on-write plus separate CoreVideo buffers preserve previous baselines and submitted images. Configure/stop reset decoder ancestry; session teardown resets sender ancestry.
- Both demos reserve at most two frames before packing. ACKs for the newest submitted frame release earlier reservations, so presentation coalescing does not strand the budget. The original lossless budget remains one; compressed modes retain three.
- Cursor remains captured by ScreenCaptureKit (`showsCursor = true`). No independent pointer transmission was introduced.
- Existing low-latency/fidelity pixel formats and encoding paths remain unchanged. The original lossless payload, pixel format and color attachments remain intact. Demo configurations use the same BGRA8 and color attachment path.
- UI exposes and persists both enum values; the existing native bridge reads those values through `TransmissionMode(rawValue:)`. Protocol 4 rejects older peers at hello instead of passing unsupported demo payloads.
- Panel catalog, product assets and native-panel lookup logic are unchanged.

## Independently executed checks

- LosslessDemoCheck: PASS, including exact pixels, sparse/skipped/cursor/unchanged/full updates, raw fallback, retained baselines, reset, budgets and corrupt LZ4/ancestry/length rejection.
- VideoModesCheck: PASS, including panel geometry, padded rows, demo decoding, retained CoreVideo images, P3 metadata, and local hardware Main10 encode/decode.
- TransportCheck: PASS, including fragmented/coalesced frames, 4.5K payload, oversized rejection, reconnect and idempotent close.
- Inline HTML JavaScript `node --check` and five transmission options: PASS.

## Limits and follow-up

The single bounding rectangle can span mostly unchanged pixels when edits are far apart. Compression and full-frame scanning add CPU/memory cost, and two frames in flight may improve throughput while increasing latency. These are explicit experimental tradeoffs, not correctness blockers. No independent Intel execution, physical dual-Mac capture, or latency improvement was established by this review. Package architecture/signature checks are recorded by implementation, not repeated here.
