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

Early exploratory runs used five samples per result-cache state and mode. Later
harness versions require one complete block: six samples for six modes, seven
for seven modes, and eight for the current eight-mode matrix.

`cold` means the PHPStan result-cache file was absent before each sample.
`warm` means the same primed result-cache snapshot was restored before each
sample. OPcache persistence and PHPStan's result cache are therefore measured
separately.

The current harness also checks the exact JIT mode in every parent and worker,
requires every AHE sample to prove that it attached to the broker's `memfd`,
compares JIT use against a pre-workload startup baseline, and rejects full or
restarting retained caches. The file-cache baseline additionally proves a
persisted bytecode hit in every process and validates the populated cache
manifest. It requires complete counterbalancing blocks. See
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

This was the first complete six-row reference run. It used the stronger
JIT-emission guard. Metadata recorded AHE base revision
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

## 2026-08-15: retained whole-function JIT compatibility fix

The original retained function-JIT prime used a dedicated broker and the same
PHPStan workload. The parent and all eight worker processes recorded successful
AHE attachment, but every worker terminated with `SIGSEGV`,
`si_code=SEGV_MAPERR`, at address `0x53`. The equivalent process-local
function-JIT run completed successfully.

Reducing PHPStan to one worker made the failure deterministic. Native debugging
first stopped in `ZEND_SEND_UNPACK_SPEC_HANDLER` with a call frame whose
`zend_function` pointer referred to overwritten process-local memory. A second
run with PHP's perf-map JIT registration mapped the retained program counter to
`PHPStan\Type\UnionType::isAcceptedBy()`. That method calls `array_map()` and
unpacks its result into a static userland method; exception backtrace collection
inside the callback exposed the stale call-frame metadata.

The Linux reattachment patch had generalized PHP's shared JIT stub table, but
the IR JIT still protected internal-function addresses under `_WIN32` or
`ZEND_WIN32` conditionals. Consequently, creator-generated whole-function code
could embed a creator-local `zend_internal_function` pointer. Disabling ASLR
stabilizes executable and mapping addresses, but it does not make allocator
produced engine metadata portable between independent processes.

`0002-enable-shm-reattachment.patch` now keys the complete semantic set of
internal-function JIT guards on `ZEND_OPCACHE_SHM_REATTACHMENT`. This makes the
IR backend resolve internal functions through process-local runtime caches,
retain the appropriate internal-handler guards, and avoid unsafe internal
function specialization in trace paths. Platform-specific memory protection,
unwinding, debugger, and perf-map branches remain keyed to their actual
platforms.

Verification after rebuilding the patched PHP 8.4.24 interpreter included:

- a creator-generated, PHAR-backed whole-function JIT fixture executed by an
  independent attacher without consuming more JIT buffer;
- the same creator-cached fixture executed concurrently by eight fresh attaching
  processes without consuming more JIT buffer;
- the Nix PHPStan parallel smoke with every parent and worker asserting attached
  whole-function JIT mode and cached PHPStan PHAR scripts;
- the pinned PHPUnit analysis reduced to one PHPStan worker; and
- the complete pinned PHPUnit analysis with one attached parent and eight
  attached workers.

All completed without process-local fallback or a crash. The reduced fixture
provides focused retained-code coverage, while the pinned PHPUnit run is the
end-to-end regression that demonstrably failed before the patch.

## 2026-08-15 22:57 UTC: retained whole-function-JIT matrix

Artifact ID: `20260815T225758Z`

This exploratory run added `ahe-jit-function` with its own broker generation and
used one complete seven-row counterbalancing block. Every mode occupied every
execution position once in each result-cache state. All 98 timed samples, the
three retained-generation primes, and the warm-result-cache transitions passed
their applicable attachment, exact-JIT-mode, emitted-code, and cache-health
checks.

Metadata recorded PHP 8.4.24, PHPStan 2.2.6, AHE revision
`5e0c69a5ae918e80c3226e17881fec5d55f4cc5a`, Linux 7.1.5-xanmod1, and an AMD
Ryzen 9 9950X3D. The worktree was dirty because it contained the seven-mode
harness changes. Other host activity may have added timing noise, so medians and
large differences are more meaningful than sub-percent comparisons.

| Result cache | Mode | Median time | Median max RSS | Speedup versus vanilla |
| --- | --- | ---: | ---: | ---: |
| cold | vanilla | 4.350 s | 198,720 KiB | — |
| cold | process-local OPcache | 4.431 s | 233,744 KiB | -1.9% |
| cold | process-local tracing JIT | 5.235 s | 271,684 KiB | -20.3% |
| cold | process-local function JIT | 11.951 s | 329,920 KiB | -174.7% |
| cold | AHE | 3.688 s | 232,556 KiB | 15.2% |
| cold | AHE plus tracing JIT | 3.878 s | 252,444 KiB | 10.9% |
| cold | AHE plus function JIT | 2.892 s | 291,948 KiB | 33.5% |
| warm | vanilla | 0.298 s | 161,952 KiB | — |
| warm | process-local OPcache | 0.510 s | 182,040 KiB | -71.1% |
| warm | process-local tracing JIT | 0.614 s | 215,796 KiB | -106.0% |
| warm | process-local function JIT | 3.927 s | 254,468 KiB | -1217.8% |
| warm | AHE | 0.284 s | 134,508 KiB | 4.7% |
| warm | AHE plus tracing JIT | 0.272 s | 153,048 KiB | 8.7% |
| warm | AHE plus function JIT | 0.286 s | 171,360 KiB | 4.0% |

Retaining whole-function JIT removed most of its repeated compilation cost. It
was 75.8% faster than process-local function JIT with a cold result cache and
92.7% faster with a warm result cache. Against retained AHE without JIT, it was
21.6% faster cold and effectively tied warm (`-0.7%`, well below the precision
justified by this run). Its one-time retained-generation prime took 7.187 s,
compared with 4.213 s for AHE and 4.333 s for AHE plus tracing JIT.

The speed comes with a memory tradeoff. AHE plus function JIT used 291,948 KiB
median max RSS cold, 25.5% more than AHE, and 171,360 KiB warm, 27.4% more than
AHE. It still used 11.5% less cold and 32.7% less warm memory than process-local
function JIT.

The retained function-JIT generation exhausted its 64 MiB JIT buffer during the
prime and reported zero free bytes afterward. The tracing generation consumed
only about 1 MiB beyond startup. The function-JIT result therefore measures a
matched, 64 MiB-capped configuration: it proves that retaining generated code
avoids the severe per-process compilation penalty, but not that every eligible
PHPStan function was compiled. A follow-up should sweep larger JIT buffers on a
quiet host and report both saturation and timing before choosing a recommended
PHPStan profile.

## 2026-08-16 00:03 UTC: stock persistent file-cache baseline

Artifact ID: `20260816T000325Z`

This is the current reference run. It added OPcache's stock
`file_cache_only` mode and used one complete eight-row counterbalancing block.
The file cache was primed by a separate cold analysis, then an untimed warm
transition cached PHPStan's restored result-cache script before warm sampling,
matching the transition already performed for each AHE generation.

Every file-cache process required a probe whose source had changed after the
prime and asserted the original return value. This proves bytecode
deserialization instead of successful process-local fallback. The prime
created 5,495 `.bin` files, including 2,417 PHPStan PHAR entries and executable
files from PHPUnit's `src` tree. All AHE attachment, exact-JIT-mode,
workload-emission, and cache-health guards also passed.

Metadata recorded PHP 8.4.24, PHPStan 2.2.6, AHE base revision
`276e653a2cec3d7c37d4b8ebefada2f90938ba4b`, Linux 7.1.5-xanmod1, and an AMD
Ryzen 9 9950X3D. The worktree was dirty because it contained the eight-mode
harness changes. Other host activity caused visible early-row noise, so the
counterbalanced medians are more useful than individual samples.

| Result cache | Mode | Median time | Median max RSS | Speedup versus vanilla |
| --- | --- | ---: | ---: | ---: |
| cold | vanilla | 4.443 s | 200,410 KiB | — |
| cold | process-local OPcache | 4.524 s | 235,074 KiB | -1.8% |
| cold | persistent OPcache file cache | 4.018 s | 245,150 KiB | 9.6% |
| cold | process-local tracing JIT | 4.934 s | 274,842 KiB | -11.1% |
| cold | process-local function JIT | 12.872 s | 330,688 KiB | -189.7% |
| cold | AHE | 3.737 s | 232,670 KiB | 15.9% |
| cold | AHE plus tracing JIT | 3.718 s | 253,618 KiB | 16.3% |
| cold | AHE plus function JIT | 2.791 s | 292,484 KiB | 37.2% |
| warm | vanilla | 0.290 s | 162,246 KiB | — |
| warm | process-local OPcache | 0.501 s | 182,222 KiB | -72.8% |
| warm | persistent OPcache file cache | 0.314 s | 148,150 KiB | -8.3% |
| warm | process-local tracing JIT | 0.609 s | 216,366 KiB | -110.0% |
| warm | process-local function JIT | 3.864 s | 255,028 KiB | -1232.4% |
| warm | AHE | 0.281 s | 134,848 KiB | 3.1% |
| warm | AHE plus tracing JIT | 0.268 s | 153,278 KiB | 7.6% |
| warm | AHE plus function JIT | 0.284 s | 171,578 KiB | 2.1% |

Stock file-cache persistence explains a meaningful part, but not all, of AHE's
bytecode-only result. It was 9.6% faster than vanilla on the cold-result-cache
workload; plain AHE was another 7.0% faster than file cache and used 5.1% less
median max RSS. With a warm PHPStan result cache, file-cache deserialization
cost more than vanilla, while AHE was 10.5% faster than file cache and used 9.0%
less median max RSS.

The larger distinction remains machine-code retention. AHE plus whole-function
JIT was 30.5% faster than stock file cache and 25.3% faster than plain AHE on
the cold workload. It was effectively tied with plain AHE on the warm workload,
where PHPStan's result cache leaves little code to execute. Its one-time prime
took 7.475 s and again exhausted the 64 MiB JIT buffer; the tracing generation
used only about 1 MiB beyond startup.

This narrows the project's value proposition. Persistent optimized bytecode by
itself offers only a modest advantage over PHP's existing disk cache. Safe
cross-process retention of whole-function JIT code produces the substantial
cold-analysis gain that stock PHP 8.4 cannot provide. The next useful
experiment is therefore a larger function-JIT buffer sweep, measuring prime
cost, saturation, cold time, and memory rather than adding more bytecode-cache
machinery.
