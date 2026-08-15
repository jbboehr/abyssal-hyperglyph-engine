# Abyssal Hyperglyph Engine: Gate of the Adamantine Oath

Experimental Zend extension infrastructure for sharing OPcache across otherwise independent PHP CLI invocations.

The repository slug is `abyssal-hyperglyph-engine`. The extension binary and build identifier use `abyssal_hyperglyph_engine`.

## Status

The project currently provides the first OPcache integration milestone:

- a PHP 8.4 patch exposes a versioned external shared-memory provider ABI;
- AHE discovers OPcache during Zend extension loading and registers before OPcache startup;
- the ABI covers allocation, detachment, locking, startup completion or failure, and shutdown;
- `ahe-php` disables ASLR before executing the packaged PHP interpreter; and
- Nix checks prove that patched OPcache initializes normally when the unfinished AHE provider declines allocation.

The provider does not persist memory yet. It deliberately falls back to OPcache's stock allocator until the broker backend is implemented. See [the architecture notes](docs/architecture.md).

## Build with Nix

Build the extension:

```console
nix build
```

Run the packaged PHP interpreter with the extension enabled:

```console
nix run . -- -v
```

`nix run` uses the `ahe-php` launcher. It disables ASLR for the PHP process and enables CLI OPcache with JIT disabled. This is an intentional, opt-in security tradeoff for controlled PHPStan and CI workloads; do not use the launcher to execute untrusted PHP code.

Build or invoke the packages individually:

```console
nix build .#ahe-php
nix run .#ahe-php -- -i
nix build .#php
```

The `php` package contains AHE and patched OPcache but does not itself disable ASLR. Use `ahe-php` for the stable-address contract.

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

AHE fails its Zend startup when it sees an unpatched OPcache or cannot register the provider. Loading AHE without OPcache remains supported for build and diagnostic checks.

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
