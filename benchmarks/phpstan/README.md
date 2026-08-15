# PHPStan benchmark

The benchmark uses the source release of
[PHPUnit 12.5.33](https://github.com/sebastianbergmann/phpunit/releases/tag/12.5.33),
pinned to commit `b98e028a26c5c5ba7e4a54be96ccf35f2914d184`. That release has 1,003 PHP
files under its configured `src` analysis path and includes a locked, vendored
PHPStan 2.2.6 toolchain with project-specific extensions.

Run it from the development shell:

```console
nix develop
scripts/benchmark-phpstan.sh --samples 5
```

At present this is also a real-world regression reproducer. The process-local
prime succeeds, but the retained-generation prime stops before timing because
independently executed PHPStan workers can fault while binding classes restored
from shared OPcache. The script emits no benchmark summary unless the prime and
its attachment probe both succeed, so this known failure cannot be reported as
a speedup. See the architecture document for the current diagnosis.

The checkout, installed Composer dependencies, logs, metadata, raw TSV samples,
and summary stay under the benchmark cache directory printed by the script.
Set `AHE_BENCHMARK_WORK_DIRECTORY` to move that directory.
The harness rejects a dirty checkout or locally modified installed Composer
packages rather than labeling them as the pinned workload.

## Cache controls

The benchmark reports two independent PHPStan result-cache states:

- `cold`: the result-cache file is absent before every timed analysis;
- `warm`: the same primed result-cache snapshot is restored before every timed
  analysis.

PHPStan's generated dependency-injection container remains warm and at the same
path throughout, so it is not confused with the result cache. Each state
alternates ordinary process-local OPcache and AHE samples to reduce ordering
bias. The AHE generation is primed with a complete, result-cache-cold analysis
before timing starts.

Every AHE parent and worker loads an attachment assertion through PHPStan's
`--autoload-file` option. A process that cannot find the AHE `memfd` mapping
exits immediately, and each timed AHE sample must produce a fresh parent marker
before it can be recorded. This prevents process-local fallback from being
reported as an AHE result.

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
