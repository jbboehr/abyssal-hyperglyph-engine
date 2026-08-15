# Abyssal Hyperglyph Engine: Gate of the Adamantine Oath

Experimental Zend extension infrastructure for sharing OPcache across otherwise independent PHP CLI invocations.

The repository slug is `abyssal-hyperglyph-engine`. The extension binary and build identifier use `abyssal_hyperglyph_engine`.

## Status

The project currently provides a Linux/PHP 8.4 reattachment prototype:

- a PHP 8.4 patch exposes the version-two external shared-memory provider ABI;
- AHE discovers OPcache during Zend extension loading and registers before OPcache startup;
- the ABI covers allocation, detachment, a shared lock descriptor, locking, startup completion or failure, and shutdown;
- `ahe-broker` retains cache and lock `memfd` descriptors and transfers them over a mutually authenticated, private Unix socket;
- `ahe-php` disables ASLR before executing the packaged PHP interpreter; and
- Nix checks prove that one CLI process can populate OPcache and a later independent process can attach and hit the same cached script.

The broker currently retains one cache generation and multiplexes concurrent clients over a shared cache and lock object. OPcache's existing inter-process locks coordinate cache writes and restarts. The broker must be started explicitly; automatic discovery, generation retirement, and complete extension fingerprinting remain future work. See [the architecture notes](docs/architecture.md).

## Build with Nix

Build the extension:

```console
nix build
```

Run the packaged PHP interpreter with the extension enabled:

```console
nix run . -- -v
```

`nix run` uses the `ahe-php` launcher. It disables ASLR for the PHP process and enables CLI OPcache with JIT and forced locker termination disabled. This is an intentional, opt-in security tradeoff for controlled PHPStan and CI workloads; do not use the launcher to execute untrusted PHP code.

Build or invoke the packages individually:

```console
nix build .#ahe-php
nix build .#ahe-broker
nix run .#ahe-php -- -i
nix build .#php
```

The `php` package contains AHE and patched OPcache but does not itself disable ASLR. Use `ahe-php` for the stable-address contract.

## Try persistent CLI OPcache

Start the broker beneath your private runtime directory:

```console
export AHE_BROKER_SOCKET="$XDG_RUNTIME_DIR/abyssal-hyperglyph-engine/broker.sock"
nix run .#broker -- --socket "$AHE_BROKER_SOCKET"
```

The broker creates the final parent directory with mode `0700` when needed and refuses directories that are not owned by the effective user or are writable by group or others. It also refuses non-socket and foreign-owned stale paths.

In another shell, run multiple PHP commands with the same socket and namespace:

```console
export AHE_BROKER_SOCKET="$XDG_RUNTIME_DIR/abyssal-hyperglyph-engine/broker.sock"
export AHE_CACHE_NAMESPACE="my-project"
export PHPSTAN_TURBO=0
nix run . -- vendor/bin/phpstan analyse
nix run . -- vendor/bin/phpstan analyse
```

PHPStan starts parallel workers with the same `PHP_BINARY`, environment, and loaded `php.ini`, so they retain AHE's broker configuration and ASLR-disabled personality. PHPStan 2.2 PHARs additionally load their bundled Turbo extension in workers only; `PHPSTAN_TURBO=0` is currently required so the parent and workers have the same extension layout. Put any custom `opcache.*` settings in the shared ini rather than passing them with `-d` to the parent, because PHPStan does not propagate arbitrary CLI ini overrides to its workers.

The effective user, namespace, SAPI, finalized Zend system ID, active `opcache.*` configuration, engine entry-point address, and requested allocation size form the current cache key. A mismatched key, unauthenticated socket, unavailable broker, or unavailable fixed address falls back to ordinary process-local OPcache.

AHE persistence requires `opcache.force_restart_timeout=0`. Stock OPcache may otherwise kill processes that retain its request lock after a forced-restart deadline, which is suitable for replaceable FPM workers but not a PHPStan parent and its sibling CLI workers. With the timeout disabled, a pending restart waits until every active participant releases the shared request lock.

Run all build, smoke, and repository checks:

```console
nix flake check --print-build-logs
```

Enter the development environment:

```console
nix develop
```

## Build with phpize

```console
phpize
./configure --enable-abyssal-hyperglyph-engine
make
./scripts/smoke-test.sh modules/abyssal_hyperglyph_engine.so
```

Load it explicitly as a Zend extension, not as a conventional PHP module:

```console
php -n \
  -d zend_extension="$PWD/modules/abyssal_hyperglyph_engine.so" \
  -v
```

To load AHE with OPcache, apply the matching patch from `patches/php/<minor>/` when building OPcache and place AHE before it:

```ini
zend_extension=/absolute/path/to/abyssal_hyperglyph_engine.so
zend_extension=opcache.so
```

AHE fails its Zend startup when it sees an unpatched OPcache or cannot register the version-two provider. A mismatched older provider ABI is therefore rejected rather than interpreted as a different callback layout. Loading AHE without OPcache remains supported for build and diagnostic checks.

## PHP version patches

OPcache is built from upstream PHP source plus a small patch series rather than vendored source copies. PHP 8.4 is the only supported series during the initial feasibility work:

```text
patches/php/8.4/0001-external-shared-memory-provider.patch
```

Additional minor versions should be added only after the broker-backed two-process test succeeds on PHP 8.4.

## License

Abyssal Hyperglyph Engine is licensed under the **GNU Affero General Public License version 3 with the Romic
Exception**:

```text
AGPL-3.0-only WITH romic-exception
```

The Romic Exception permits AHE to be linked or combined with other code without subjecting that other code to the AGPL
merely because of the linking or combination. Modifications to AHE itself remain subject to the AGPL, including its
source-availability requirements for modified versions made available over a computer network.

See [LICENSE.md](LICENSE.md) and [docs/LICENSE_EXCEPTION.md](docs/LICENSE_EXCEPTION.md) for the complete terms.
