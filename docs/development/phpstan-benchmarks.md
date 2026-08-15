# PHPStan development benchmark log

This log preserves the benchmark results used to guide AHE development. They
are local measurements, not general performance claims. The raw logs remain in
the benchmark work directory and are not part of the repository.

## Workload and controls

All recorded runs used:

- PHP 8.4.24;
- PHPStan 2.2.6 from the PHPUnit repository;
- PHPUnit 12.5.33 at commit
  `b98e028a26c5c5ba7e4a54be96ccf35f2914d184`;
- PHPStan Turbo disabled so the parent and workers had the same extension
  layout.

The first three runs used five samples per result-cache state and mode. The
current run uses the six samples required to complete the six-mode
counterbalancing block.

`cold` means the PHPStan result-cache file was absent before each sample.
`warm` means the same primed result-cache snapshot was restored before each
sample. OPcache persistence and PHPStan's result cache are therefore measured
separately.

The current harness also checks the exact JIT mode in every parent and worker,
requires every AHE sample to prove that it attached to the broker's `memfd`,
compares JIT use against a pre-workload startup baseline, and rejects full or
restarting retained caches. It requires complete six-row counterbalancing
blocks. See
[`benchmarks/phpstan/README.md`](../../benchmarks/phpstan/README.md) for the full
methodology.

The machine model and AHE Git revision were not captured in the first three
historical results. Comparisons within a run are useful, but comparisons between
runs should be treated as directional. The current harness records both fields.

## 2026-08-15 08:28 UTC: initial persistence comparison

Artifact ID: `20260815T082811Z`

This earlier version of the harness compared ordinary process-local CLI
OPcache (`baseline`) with retained AHE OPcache. It used GNU `time`'s
centisecond-resolution elapsed time and alternating execution order. Later runs
use nanosecond wall-clock measurements and balanced mode ordering, so this run
is retained as historical evidence rather than the current reference.

| Result cache | Mode | Median time | Median max RSS | Speedup versus baseline |
| --- | --- | ---: | ---: | ---: |
| cold | process-local OPcache | 6.280 s | 230,852 KiB | — |
| cold | AHE | 5.470 s | 228,756 KiB | 12.9% |
| warm | process-local OPcache | 0.580 s | 180,848 KiB | — |
| warm | AHE | 0.320 s | 133,540 KiB | 44.8% |

## 2026-08-15 18:22 UTC: tracing-JIT matrix

Artifact ID: `20260815T182222Z`

This run added vanilla PHP and matched 64 MiB tracing-JIT variants. AHE and
AHE plus tracing JIT used separate retained generations.

| Result cache | Mode | Median time | Median max RSS | Speedup versus vanilla |
| --- | --- | ---: | ---: | ---: |
| cold | vanilla | 4.553 s | 200,636 KiB | — |
| cold | process-local OPcache | 4.339 s | 234,036 KiB | 4.7% |
| cold | process-local tracing JIT | 5.039 s | 274,228 KiB | -10.7% |
| cold | AHE | 3.898 s | 232,624 KiB | 14.4% |
| cold | AHE plus tracing JIT | 3.882 s | 254,224 KiB | 14.7% |
| warm | vanilla | 0.314 s | 162,356 KiB | — |
| warm | process-local OPcache | 0.524 s | 183,068 KiB | -66.9% |
| warm | process-local tracing JIT | 0.628 s | 216,404 KiB | -100.0% |
| warm | AHE | 0.292 s | 134,536 KiB | 7.0% |
| warm | AHE plus tracing JIT | 0.283 s | 152,264 KiB | 9.9% |

Tracing JIT made process-local PHPStan slower and increased memory use. Once
retained by AHE, tracing JIT was effectively neutral on the cold workload and
only slightly faster on the warm workload. The retained status probe showed
that roughly 1 MiB of the 64 MiB JIT buffer was unavailable. This historical
run did not subtract the startup stub allocation, so it cannot establish how
much of that space contained PHPStan-generated traces. The current harness
captures a pre-workload baseline for that purpose.

## 2026-08-15 19:10 UTC: whole-function-JIT matrix

Artifact ID: `20260815T191004Z`

This run repeated the tracing modes and added process-local
`opcache.jit=function`, PHP's whole-function, compile-on-script-load preset.
AHE plus function JIT was not timed because its compatibility probe crashed;
recording a fallback or partial sample would have been misleading.

This run used only five rows of a six-mode ordering and therefore did not put
every mode in every execution position. Its results remain useful as a local
signal, but may contain position bias. The harness now requires sample counts
in complete six-row blocks.

| Result cache | Mode | Median time | Median max RSS | Speedup versus vanilla |
| --- | --- | ---: | ---: | ---: |
| cold | vanilla | 4.350 s | 200,216 KiB | — |
| cold | process-local OPcache | 4.530 s | 233,160 KiB | -4.1% |
| cold | process-local tracing JIT | 5.031 s | 272,192 KiB | -15.7% |
| cold | process-local function JIT | 12.062 s | 336,220 KiB | -177.3% |
| cold | AHE | 3.790 s | 233,096 KiB | 12.9% |
| cold | AHE plus tracing JIT | 3.781 s | 251,844 KiB | 13.1% |
| warm | vanilla | 0.307 s | 162,108 KiB | — |
| warm | process-local OPcache | 0.514 s | 182,280 KiB | -67.4% |
| warm | process-local tracing JIT | 0.616 s | 215,788 KiB | -100.7% |
| warm | process-local function JIT | 3.913 s | 254,904 KiB | -1174.6% |
| warm | AHE | 0.287 s | 134,600 KiB | 6.5% |
| warm | AHE plus tracing JIT | 0.277 s | 152,988 KiB | 9.8% |

Relative to ordinary process-local OPcache, function JIT was 166.3% slower in
the cold state and 661.3% slower in the warm state. It compiles complete
functions whenever their scripts load, so every short-lived PHPStan worker pays
an eager compilation cost for a large PHAR. The warm result-cache workload
makes that fixed cost especially visible.

## 2026-08-15 19:38 UTC: counterbalanced reference matrix

Artifact ID: `20260815T193826Z`

This is the current reference run. It used a complete six-row counterbalancing
block and the stronger JIT-emission guard. Metadata recorded AHE base revision
`c08678d9f71d1e3697de5a5ab406980a124ada55`, a dirty benchmark worktree, Linux
7.1.5-xanmod1, and an AMD Ryzen 9 9950X3D.

| Result cache | Mode | Median time | Median max RSS | Speedup versus vanilla |
| --- | --- | ---: | ---: | ---: |
| cold | vanilla | 4.547 s | 198,746 KiB | — |
| cold | process-local OPcache | 4.851 s | 234,584 KiB | -6.7% |
| cold | process-local tracing JIT | 5.116 s | 273,270 KiB | -12.5% |
| cold | process-local function JIT | 13.326 s | 332,096 KiB | -193.1% |
| cold | AHE | 4.362 s | 233,070 KiB | 4.1% |
| cold | AHE plus tracing JIT | 4.244 s | 252,996 KiB | 6.7% |
| warm | vanilla | 0.305 s | 162,004 KiB | — |
| warm | process-local OPcache | 0.526 s | 183,208 KiB | -72.5% |
| warm | process-local tracing JIT | 0.635 s | 215,784 KiB | -108.2% |
| warm | process-local function JIT | 4.073 s | 253,894 KiB | -1235.4% |
| warm | AHE | 0.293 s | 133,832 KiB | 3.9% |
| warm | AHE plus tracing JIT | 0.279 s | 152,882 KiB | 8.5% |

The attached tracing-JIT startup baseline had 67,105,972 bytes free. After the
PHPStan prime, 66,064,288 bytes remained. PHPStan therefore consumed 1,041,684
bytes beyond startup's 2,876-byte stub allocation. This validates workload JIT
emission while confirming that less than 1 MiB of the nominal 64 MiB buffer was
useful for generated PHPStan code.

The counterbalanced run preserves the earlier conclusion: process-local
whole-function JIT is especially expensive for this short-lived, parallel
workload; tracing JIT adds little to retained AHE; and AHE remains most valuable
when PHPStan's own result cache makes each invocation short.

## AHE plus function JIT compatibility result

The attempted retained function-JIT prime used a dedicated broker and the same
PHPStan workload. The parent and all eight worker processes recorded successful
AHE attachment. After work was dispatched, every worker terminated with
`SIGSEGV`, `si_code=SEGV_MAPERR`, at address `0x53`. The equivalent
process-local function-JIT run completed successfully.

This narrows the problem to executing retained whole-function JIT code after an
independent attachment. The existing JIT smoke test does not cover that case:
its attaching process emits and executes new JIT code through the retained stub
table, but it does not execute machine code generated by the creator process.

## Next slice: retain whole-function JIT safely

AHE plus function JIT is the priority for the next development slice. Work
should proceed in this order:

1. Add a small two-process regression in which the creator compiles a cached
   function under `opcache.jit=function` and an independent attacher executes
   that exact retained function. Keep the PHPStan crash as the end-to-end case,
   not the first debugging loop.
2. Reduce the PHPStan case to one worker and obtain a native backtrace from a
   debug PHP build. Record the failing JIT program counter and map it back to
   the cached function and generated code range.
3. Compare creator and attacher state for the failing `zend_op_array`, including
   its JIT entry point, runtime-cache/map-pointer state, function metadata, and
   JIT stub handlers. Audit remaining Windows-only JIT reattachment branches;
   the current Linux patch generalizes the shared stub table but may not cover
   all process-local state embedded by compile-on-script-load JIT.
4. Patch the narrowest missing reinitialization or relocation path. The target
   is reuse of creator-generated function code, not silent process-local
   recompilation or disabled JIT.
5. Extend the Nix checks with both the reduced two-process function-JIT test and
   the PHPStan parallel smoke test. Each must assert the exact `function` mode,
   successful `memfd` attachment, and execution in a fresh process.
6. Restore `ahe-jit-function` to the benchmark only after those checks pass,
   then rerun the six-sample cold/warm matrix against its process-local
   counterpart.

The slice is complete when an independently launched PHPStan worker can execute
creator-generated whole-function JIT code from the retained generation and the
harness records an AHE plus function-JIT sample without fallback.
