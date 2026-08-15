# PHPStan benchmark

The benchmark uses the source release of
[PHPUnit 12.5.33](https://github.com/sebastianbergmann/phpunit/releases/tag/12.5.33),
pinned to commit `b98e028a26c5c5ba7e4a54be96ccf35f2914d184`. That release has 1,003 PHP
files under its configured `src` analysis path and includes a locked, vendored
PHPStan 2.2.6 toolchain with project-specific extensions.

Run it from the development shell:

```console
nix develop
scripts/benchmark-phpstan.sh --samples 6
```

This also provides real-world regression coverage for cross-process class
linking. The retained-generation prime and every timed AHE sample must prove
that the PHPStan parent and workers attached successfully before the harness
records a result. The smaller `scripts/reproduce-class-linking.sh` case covers
the original reduction using one cached class that extends an internal PHP
class.

The checkout, installed Composer dependencies, logs, metadata, raw TSV samples,
timed AHE population runs, and summaries stay under the benchmark cache
directory printed by the script.
Set `AHE_BENCHMARK_WORK_DIRECTORY` to move that directory.
The harness rejects a dirty checkout or locally modified installed Composer
packages rather than labeling them as the pinned workload.

Completed development measurements and their interpretation are recorded in
[`docs/development/phpstan-benchmarks.md`](../../docs/development/phpstan-benchmarks.md).

## Cache controls

The harness runs six modes with the same patched PHP binary and extension set:

- `vanilla`: CLI OPcache disabled;
- `opcache`: ordinary process-local CLI OPcache;
- `opcache-jit`: process-local OPcache with a 64 MiB tracing JIT buffer;
- `opcache-jit-function`: process-local OPcache with PHP's whole-function,
  compile-on-script-load JIT preset;
- `ahe`: broker-retained OPcache with JIT disabled;
- `ahe-jit`: a separately broker-retained generation with the same JIT profile
  as `opcache-jit`.

The process-local JIT modes isolate each JIT strategy's effect from persistence.
Comparing `ahe-jit` with `opcache-jit` isolates the effect of retaining a
tracing-JIT cache. The two AHE modes use separate brokers so their different
allocation sizes and OPcache configurations never contend for the prototype
broker's single generation.

Whole-function JIT is intentionally process-local in this matrix. Its
compile-on-script-load machine code currently crashes independently attached
PHPStan workers after they receive work, while the equivalent process-local
workers complete. AHE must not advertise or benchmark that combination until
its additional process-local JIT state is identified and reinitialized during
reattachment.

The benchmark reports two independent PHPStan result-cache states:

- `cold`: the result-cache file is absent before every timed analysis;
- `warm`: the same primed result-cache snapshot is restored before every timed
  analysis.

PHPStan's generated dependency-injection container remains warm and at the same
path throughout, so it is not confused with the result cache. A balanced
Latin-square order puts every mode in every execution position and varies its
neighbors to reduce ordering and carryover bias. Sample counts must be a
multiple of the six modes so the harness always executes complete
counterbalancing blocks. Each AHE generation is primed with a complete,
result-cache-cold analysis before sample collection; these cache-populating
invocations are timed and reported separately rather than mixed with attached
samples. Before warm-result-cache samples begin, each retained generation
processes that snapshot once so the result-cache PHP file itself is already
represented in OPcache; this transition is validated but not mixed into the
steady-state timings.

Every mode loads the same file through PHPStan's `--autoload-file` option so the
result-cache configuration is identical. It asserts the expected JIT state in
every parent and worker; in AHE modes it also asserts attachment. A process that
cannot find the AHE `memfd` mapping exits immediately, and each timed AHE sample
must produce a fresh parent marker before it can be recorded. A post-sample
probe additionally compares the retained JIT buffer with a baseline captured
after startup allocated its stub handlers but before PHPStan ran. It therefore
requires workload-generated JIT code rather than treating startup allocation as
emission. These guards prevent configuration drift, result-cache invalidation,
and process-local fallback from distorting the comparison.

PHPStan runs its engine from a PHAR. With PHP 8.4's normal OPcache settings,
timestamp and file-update checks cannot obtain a timestamp for internal PHAR
stream entries, so those entries are not cached. [`opcache.ini`](opcache.ini)
disables both checks for **both** sides of this controlled benchmark. This is
only safe because the PHPStan toolchain and checkout are pinned. Stop the broker
and start a fresh benchmark whenever PHPStan or an executable dependency
changes. It also gives OPcache 512 MB and 100,000 script-table entries so the
complete PHPStan engine and its parallel workers do not force a mid-analysis
cache restart. A post-prime probe and a fresh post-sample probe reject a full or
restarting cache before any AHE result is accepted.

The benchmark also sets `PHPSTAN_TURBO=0` so PHPStan's parent and worker
processes have the same loaded-extension layout. It supplies the parent with the
same `sys_temp_dir` system setting that PHPStan adds to every worker command;
this eliminates one source of startup-layout drift before OPcache reattaches. An
attached post-warm-up probe must find PHPStan PHAR scripts in shared OPcache
before any samples are accepted.
