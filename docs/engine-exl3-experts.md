# Engine: EXL3 trellis experts (`expert_layout == .exl3_k4`)

How routed experts in turboderp's EXL3 trellis format are decoded and multiplied: the rate, codebook and window a
pack names, the prefill GEMM and the four-dispatch decode chain, and the parity bars their tests hold. Read this
before touching `src/exl3/`, `src/expert_quant.zig` or `moeExl3`.

Index: [CLAUDE.md](../CLAUDE.md#docs-index). Related: [pack-format](pack-format.md) (the on-disk contract),
[engine-kernels](engine-kernels.md), [engine-expert-streaming](engine-expert-streaming.md),
[perf-baselines](perf-baselines.md#exl3), [quality-kld](quality-kld.md).

## Code map

| File | Role |
|---|---|
| `src/expert_quant.zig` | Expert layout detection from PACKED shapes: `.quantized_split` (affine banks) vs `.exl3_k4` (trellis); affine (bits, group_size) solved from geometry |
| `src/exl3/root.zig` | The `sushi_exl3` module's host API: `expert_quant` parse (`parseExpertQuant`), `admitTopK`, `trellisAdmitted`, `moe` (the one dispatch) |
| `src/exl3/expert_exl3.zig` | Host reference decoders (MUL1, MCG), `Rate`, `Window`, `Decode`, fixtures |
| `src/exl3/expert_exl3_kernels.zig` | Prefill run-aligned 32-row window GEMM (NAX body, K4 fast branch; simdgroup-matrix body off NAX; scalar body), decode chain (`moeSwigluFused`), `DECODE_ROWS_MAX` (16), `usesPrefillArm` |
| `src/expert_bf16_kernels.zig` | bf16 selected-expert kernels over a slab (`gateUpSwiglu`; `downReduce`) for the unquantized HF checkpoint |

**`src/exl3` is a module** (`sushi_exl3`), so another MLX host (mlx-serve) can serve EXL3 packs through the same code.
It reaches `mlx`, `log` and `io_util` through an `mlx_host` import whose root file exposes them as `pub const`; here that
root is `src/main.zig` (and `src/tests.zig` for tests), and it can never import a Sushi file by path. Its tests run as
their own artifact (`exl3-test`) on `zig build test`.

The NAX compile-probe regression test checks hardware capability independently
of the runtime failure latch. It deliberately latches dispatch off before
probing the real kernel, so an earlier SIMD fallback cannot hide a broken NAX
kernel on supported hardware.

## Format as the engine sees it

- Routed experts are stacked per layer as `[E, ...]` so gather kernels index expert e on axis 0; 16x16 tiles,
  `suh`/`svh` with the H128 Hadamard; `config.json` carries `expert_quant = {format: exl3, k, codebook: mul1|mcg}`
  (plus `window`); per-tensor rate read from the trellis shape. Every other module stays the affine pack's.
- **A rate is K = n/16**, n the packed halfwords per 256-weight tile (36 = K2.25, 48 = K3, 64 = K4): weight t's
  codeword is the 16-bit window ending at `((t+1)*n)>>4`, so its fresh bits follow from n and the pattern is never
  stored. Even n in [16, 128] admits (K1 to K8); `expert_quant.k` may be fractional JSON.
- **Every reader keys on n, never on an integer K** (`exl3.Rate`, kernel template `NHW`, cache keys,
  `exl3ExpertBytes`); a K printed anywhere reads 2.25, not 36.
- **Every fast path serves every admitted n; a guard test enumerates them** (`every admitted rate takes the fast
  arms`). The funnel readers take their word indices and shifts from n at compile time: eight weights span n/2 whole
  bits, and 16 weights span n. Below n64 every codebook reads through them. n64 keeps its packed K4 branch, which does
  the same reads at a word-aligned rate, one output tile per threadgroup:
  - decode GEMV lane: 64 bits ending at the lane's last bit. A third word is read only when the first codeword can
    start before the two words (every n from 42 to 62 but 48), and then on every lane: a branch around that load on
    the lane's bit alignment kept every byte and doubled the n42 pair GEMV
    ([perf-baselines](perf-baselines.md#exl3-lane-third-word)).
  - simdgroup-matrix group: one or two 32-bit funnels, split at the widest weight whose first codeword still fits.
  - NAX fragment: one funnel per quad of weights; above n50 a quad's codewords pass 32 bits, and the funnel reads 64
    bits from three words.
- **The window is a pack field** (`expert_quant.window`, absent = 16, 8..16 admitted): the codeword is masked to the
  window in the one helper every weight kernel inlines, and kernel slots are keyed by codebook AND window. A w16
  bitstream decodes to different weights at every other window, so a window can never come from a flag.
- **The codebook follows the MODEL at every dispatch**: `exl3.moe` calls `kernels.setDecodeParams`
  (codebook + window) before each dispatch because several EXL3 packs can be resident at once; every weight kernel
  inlines `exl3_pairh` from `codebookHelpers`, built per (codebook, window). A codebook name this build does not decode is refused at load
  ([pack-format](pack-format.md#configjson)). A/B lever:
  `SUSHI_EXL3_CODEBOOK_AB=1` on the `codebook A/B` test.
- **A shard's `__metadata__` stamp is CHECKED against `expert_quant` before upload**
  (`mimo_source.validateShardStamps`): see [pack-format](pack-format.md#the-shard-stamp).
- `num_experts_per_tok` above 32 refuses by name (`Exl3TopKExceedsReduceBank`).

<a id="mimo"></a>
## MiMo EXL3 packs

A MiMo EXL3 pack serves RESIDENT: its banks nest under `model.layers.` (qwen4's under
`language_model.model.layers.`), `expertStreamingRequired` excepts `.exl3_k4`, and the trunk still takes the
source FP8→bf16 loader (`usesMimoSourceTrunk`), billed dense by `mimoSourceResidentBytes`. See
[arch-mimo-v2](arch-mimo-v2.md).

<a id="glm"></a>
## GLM clamped experts

GLM-5.3 routes 288 experts top-8 (hidden 4096, expert width 2048; the shipped Sushi-2.4bpw is MCG W14, K2.25 (n36) in most layers and K2.5 (n40) in
layers 37–44; every path serves any window) through
`moeClamped`: the gate upper clamp and symmetric up clamp (limit 10) apply in FP32 before SwiGLU, at every packed rate
the format admits (n16 to n128 in eighth-bit steps). Bank geometry (H128 alignment, matching gate/up/down shapes and expert counts, U16
trellises, F16 scale grids, routed input/score shapes) is checked before dispatch; router IDs inside the expert range
are the router's precondition, never synced to the CPU. Every path below is bit-identical to the staged chain at every
admitted rate and is always on for eligible shapes ([arch-glm5-next](arch-glm5-next.md)).

- **GLM's cooperative GEMV is not MiMo's.** `INDEXED_COOP_SOURCE` writes all lane partials and adds them r=0..15
  outside simdgroup g=0..3 before the F16 store; MiMo's grouped epilogue (XOR shuffles, K-split planes) rounds
  differently, so a MiMo kernel is never a GLM oracle. Gate and up share one dispatch (grid Z picks the projection).
- **Decode** keeps slots in top-k order and prepares both gate/up input planes from token rows in one kernel, stored
  in GEMV lane order (tile rows 2q, 2q+1, 2q+8, 2q+9) so each lane loads one `half4` (rows 1–16, equal-shaped MCG
  banks at any window; component −17% at 1 row, −29% at 16). The middle is prepared separately in lane order and the down reads it
  by `half4` (`downLanePrepare` + `downLaneCoop`: every admitted n, MCG at any window, BF16 out; −10–15% against the fused
  middle/down, which now serves only what the lane path declines).
- **Verification rows share weight reads** (`src/exl3/glm_group2.zig`, 3–4 BF16 rows, 4096/2048, top-8, clamp 10,
  MCG at any window, every admitted n, gate/up equal and down free): a ballot pairs equal-expert slots in original slot order, the leader decodes each weight once and
  feeds two independent FP32 accumulator sets, and a serial 4 KiB member reduction keeps the r-then-simdgroup order.
  Singleton leaders run the unchanged body. Routed-chain replay −20% on layers with expert overlap; DFlash2 N2 512/64
  decode 42.43 → 45.45 tok/s at n36 (`ba106e5e`); at n40 (Sushi-2.5bpw, kv8, A4 DFlash2, ABBA in one boot, AC power, `taskpolicy -a`, lock `glm-n40`) +3.2% at 512/64 (4/4 pairs) and +5.0% at 8K/128, same bytes. Real 8K verify rounds are singleton-heavy (70% of assignments). The gate is `glm_group2.servesRate`; a guard test enumerates every admitted n.
- **Prefill** prepares gate/up straight from token rows, shares one window table across the three projections,
  builds the inverse routing on the GPU (at most 512 experts) and finishes from the sorted down plane; the stride
  fallback scatters. WIN32 already skips its second 16-row MMA for runs of at most 16 rows (512-token prompts touch a
  median 230 of 288 experts).
- **Full T2048 chunks transpose the grid** (`src/exl3/glm_prefill_grid.zig`, B1, H4096/I2048, E288, top-8, every admitted
  n including mixed per-projection rates, MCG at every window (one NAX kernel per window, like the GEMM), clamp 10): physical X walks routing windows and Y the 128-column output stripes; logical IDs, dot body and
  stores are unchanged. Actual L20 chain 19.64 → 17.96 ms at n36 (−8.6%, 11/11); at n40 (Sushi-2.5bpw, kv8, ABBA in one boot, AC power, `taskpolicy -a`, lock `glm-n40`) prefill +4.5% at 8K and +2.7% at 32K, same bytes. A test enumerates every admitted n against the sorted chain. The T2048 routed chain is GEMM-bound
  (gate/up ≈60%, down ≈30%; sort/prepare/middle/finish ≈1.75 of 17.35 ms).
- **MCG/W12 decode is pure ALU** (mask, multiply/mask/xor, half adds): there is no codebook table or expanded weight
  plane to cache, and cross-round expert reuse at 8K is only ~40%.

Ruled out for GLM experts (each exact unless noted; "component" = an isolated replay on real banks):

- Window height 16 or one 16-row accumulator: 7–19% slower per GEMM; WIN32 keeps decode reuse and two-tile scheduling.
- 64/32-thread output groups: group 64 only 0.7–1.8% faster, group 32 flat or slower; 128 kept.
- n36 SIMD word sharing (load 36 words once, shuffle): 83–86% slower; fewer source reads are not fewer transactions.
- Three verify rows through the sorted prefill NAX body: 11–32% slower (7–19% with 25-window capacity), not exact.
- Grid transpose at T1536–2047: −9.6% on a sliced component, +1.24% on the 2037-token model gate.
- Three-member read sharing: −9% on one high-overlap case, +2–8% elsewhere; parallel reduction lost every case.
- Group2 partner prepass (one dispatch emitting partner slots): 0.16% median, 5/11 wins.
- Singleton-only/paired-only gate/up kernels: +1.61%, 0/11 on the 42-layer T3 replay.
- Grouped middle/down fusion for verify rows (12 KiB staged members): +11.52%, 0/11.
- One-row fused middle/down: model decode 26.18 vs 26.54 tok/s; superseded by the lane down.
- Route6 (keep the 6 heaviest of 8 routes at T2048): −20% on L20 but code mean KL 0.334 (bound 0.01) on the 16K screen.
- Steady 4096-row prefill chunks (grid −8.4% at 4096): moved IndexPool NAX engagement and failed the 16K screen
  (code mean KL 0.034, prose max 0.18).
- Expert-pair prefill (join two routed layers' gate/up): exact L20 −2.47% component, model/assistant gate never
  closed; code deleted.

## Kernels

- **Prefill**: run-aligned 32-row windows, K-generic cooperative readers, the NAX 16x32x16 GEMM body with a K4 fast
  branch; ONE GEMM config reused across window counts (a per-row-count JIT compiled per novel prompt length).
- **At the two served geometries (`mimoPrefillOn`: MiMo, Flash-Next) the routing never leaves the GPU**: one
  threadgroup (a thread per expert, at most 512) builds the window table and the inverse sort order, and the finish
  reduce reads the sorted down plane through that inverse, bytes equal to un-sorting it first. Any other geometry
  builds the table on the host (a sync) and un-sorts with a copy ([perf-baselines](perf-baselines.md#exl3-gpu-routing-meta)).
- **The NAX body's x loads carry no bounds branch**: a lane's row pointers are clamped into the input once per run
  (a padded row reads a live neighbour whose product is never stored), the k loop is unswitched on the window's
  second 16-row block and unrolled by two. Every row's products are the branch-guarded body's, so its bytes are
  `GEMM_NAX_REFERENCE_SOURCE`'s at every admitted rate (the test's reference); -25% per GEMM at MiMo geometry
  ([perf-baselines](perf-baselines.md#mimo-prefill-nax-body)).
- **Prefill off NAX** (M1–M4, or NAX declined): the 8x8 `simdgroup_matrix` body computes D = W^T X^T so each lane's
  eight-weight slot group lands straight in its A fragments (the tile layout is the MMA fragment layout). f16 x and
  128-multiple widths only; anything else takes the scalar body. Not byte-identical to the scalar body (sum order).
- The funnel readers' codewords and decoded weights equal the host tile decode's at every n, so the GEMM
  accumulation order and output bytes are unchanged (n32..36 read a group through one funnel, wider rates two).
- **Its block count is compile-time** (`(WIN+7)/8`), never the run's: a data-dependent bound over the
  `simdgroup_matrix` arrays spilled them, 2.6x slower. Short runs pay the padding and still win
  ([perf-baselines](perf-baselines.md#m2max-64gb)).
- **Decode**: four dispatches per MoE layer — pair prepare, split-K pair GEMV with f32 inner planes, fused mid+down
  GEMV, f32 finish reduce (`moeSwigluFused`; top-k ≤ 32, named refusal above). On MiMo geometry the SwiGLU mid is
  prepared once per (row, expert) (`preparedMidOn`, disabled for Qwen; like `mimoPrefillOn` it keys on geometry,
  never on the rate), and at two or more rows the pair input too, in its own dispatch (`pairPrepare`): five
  dispatches. A pair threadgroup would otherwise re-derive its K span of x (64 times per slot); one row keeps that
  fused prepare, where the extra dispatch costs more than it saves. Rows ≤ `DECODE_ROWS_MAX` or verify rows take this
  chain; wider takes `moePrefill`. The MTP head's MoE rows ride the decode chain and refuse wider
  (`Exl3MtpRowsExceedDecode`).
- **The prepared pair input is stored in GEMV lane order** (`LANE_ORDER_SLOT`: each 16-row tile keeps rows 2q,
  2q+1, 2q+8, 2q+9 at 4q..4q+3), so a lane reads its four as one half4 (`laneQuadReads`). Same values in the same
  order: the pair planes keep the self-preparing kernel's bytes. The same layout for the prepared middle measured no
  gain on the down (mid + down 52.1 vs 51.7 us at 1 row, 145.1 vs 145.9 at 4) and is not taken.
- **Streamed serial decode** can add its already gated shared expert in the finish reduce, removing a dependent
  elementwise dispatch. The routed sum is rounded to its output dtype before the shared addition, matching the
  separate store and add bit for bit. Other widths, mixed gate/up rates and dtype mismatches retain the separate add.
- **The decode GEMVs are bound by fixed per-tile work, not DRAM** (64-bit index math, two word loads and a 64-bit
  shift, four input reads, loop control). The lane-funnel arms (`gemvLayout`: every n below 64) carry two output
  tiles per threadgroup, load both k-tiles of an iteration before decoding, and bump pointers; the per-tile
  accumulation order is unchanged, so the bytes equal the one-tile generic reader's (`FUNNEL=0`, the test's
  reference). A layout that changes which simdgroup sums which k-tile (8 simdgroups) is NOT bit-identical.
- A rate on the generic reader decodes ~40% slower per GEMV than on the funnel, with no other symptom. The engagement
  line `[exl3] n<n> funnel engaged arm=<arm>` names the rate and arm in a live log.
- **A reader change is timed on every served pack's decode before it lands** (forward meter, against its parent): the
  byte-identity and engagement tests pass on a reader that runs at half speed. Speed is owed to K1.5 to K4, the
  range the converters write: the test `every K1.5 to K4 rate decodes within a margin of n48` holds each even n from
  24 to 64 within 1.4x of n48's GEMV steps (n64's packed branch 1.8x). Rates below K1.5 and above K4 stay admitted and tested for correctness,
  never timed. `SUSHI_EXL3_LOWK_UBENCH=1` on the exl3 test binary prints n24..n48's decode chain and sorted prefill
  GEMMs over n32's at Flash-Next geometry (w8, w12, w15), interleaved in one process.
- **MiMo verify rows share an expert's weight reads** (`PAIR_GEMV_GROUPED_SOURCE`, `DOWN_PREPARED_GROUPED_SOURCE`;
  prepared-mid geometry, 2+ rows): among an expert's slots, each even-ranked slot leads itself and the next one,
  decodes each weight once and feeds both members in the single-slot order, so every row's bytes are its one-row
  decode tick's. Two members only: four spill their accumulators. Not on Flash-Next, whose rows share too few experts.
- **A decode GEMV slot is bound by its own FMA and input path**, not the weight decode or DRAM, so deduplicating
  shared experts recovers only 4-7% of the expert kernels at 3-4 rows.
- Dead for the decode GEMVs (microbenched): 4 or 8 tiles per threadgroup, software prefetch, 2 simdgroups, a
  threadgroup LUT decode, a 24-bit multiply split, half2 input reads, bitfield extracts.
- Dead for the prefill GEMM on the NAX body (MiMo and Flash-Next, outputs bit-identical, all slower): 64-row windows
  with one decode feeding 4 MMAs (+7-18%), a threadgroup-shared double-buffered decode (+30%), decoding tile k+1
  before tile k's MMA (+27%), 256- or 64-thread groups (+12% at 2048 rows); on the branch-free body: a threadgroup
  LUT decode of the w12 codebook (+32%), a per-k-step threadgroup barrier (+9%), unroll 4 (+20% over unroll 2),
  64-row windows again (+9-13% on gate/up). The kernel is register/occupancy bound: added live state loses.
- Dead for prefill routing: a counting sort (histogram, scan, stable scatter) in place of the argsort, exact with
  ties: -0.03 to -0.16 ms per MoE layer as a component, yet Qwen 2.6bpw prefill 5-10% slower in an A B B A (de867e94 era).
- **The SwiGLU chain is f32**: gate, up, sigmoid, SiLU and their product stay in f32 registers through the multiply
  by the down suh. In f16, MiMo's activations put gate and up near 400 each and the product past 65504, so a whole
  routed row became inf. The next ceiling is the f16 down inner plane (about 2x above the measured peak).
- **The shared-expert add must free the routed output it consumed**: it once retained 1920 MiB per 8192-token chunk
  (the 48k prefill cliff). Owned-copy hidden captures at the chunk boundary; kernel configs dropped on their error
  paths.
- **Levers**: `SUSHI_EXL3_GEMM_WIN`, `SUSHI_EXL3_WIN_ALIGN` (window geometry A/B); diagnostics
  `SUSHI_EXL3_LAYER_UBENCH`, `SUSHI_EXL3_UNION_HIST`, `SUSHI_EXL3_SWIGLU_MAXABS`, `SUSHI_EXL3_GEMM_ARMS` (served vs
  reference NAX body, interleaved, at MiMo geometry; `SUSHI_EXL3_GEMM_COUNTS` replays the per-layer `[exl3-counts]`
  lines `SUSHI_EXL3_UNION_HIST` logs on a prefill).

## Parity bars

- **Quality bar**: KLD vs the bf16 teacher (`sushi kld capture|compare`), never bytes against the affine pack.
  The EXL3 kernel arms are not byte-identical to any composite (they round once). MTP: EXL3 packs take the chip's
  generic depth row ([engine-mtp](engine-mtp.md#round-cost-table)).
- **A GEMM/GEMV parity bar is relative to the SUMMANDS, never the result** (`Exl3GemmParity`): a trellis dot product
  cancels orders below sum|w·x|, so a result-magnitude floor is seed-locked. Element ceiling = one f16 store + an
  f32 accumulation `in_dim` deep; whole-tensor RMS no worse than 3x mlx's own f16 matmul over the decoded weights
  (`measureInnerGemmParity`). A parity case sweeps `PARITY_SEEDS`, never one chosen seed.
- **Test every arm at REAL magnitudes against a TRUE f32 oracle** with a finiteness assert (outlier residual
  channels, products in the 1e4..1e5 range). A host oracle that mirrors the kernel's own f16 stores cannot see a
  saturation. When a pack "mostly works", capture per-layer max|x|, max|gate*up|, max|down inner| on a real prompt
  first.
- **Score the Metal arms on a real pack's own bytes** (real suh vectors span four decades), not only synthetic
  trellises. The w12 fixture (`exl3_k2p5_mcg_w12_linear.safetensors`) certifies the window convention against the
  converter's own decode.
- A "systematically wrong but not garbage" pack whose reference decoders agree points at live-path numerics OR at
  the pack's own weights along real activations (a converter-side defect; converter details live in the private
  repo), not the bit layout.
