# Abyssal Hyperglyph Engine: Gate of the Adamantine Oath

Experimental Zend extension infrastructure for sharing OPcache across otherwise independent PHP CLI invocations.

The repository slug is `abyssal-hyperglyph-engine`. The extension binary and build identifier use `abyssal_hyperglyph_engine`.

## Status

The project currently provides an inert Zend extension scaffold. It proves the build, loading, packaging, and CI paths without modifying PHP or OPcache behavior yet.

The intended design is a small OPcache patch that permits shared-memory handlers and their synchronization mechanism to be supplied by another component. This Zend extension will provide a broker-backed handler, using an anonymous file descriptor and a background process to retain the cache between CLI processes. See [the architecture notes](docs/architecture.md).

## Build with Nix

Build the extension:

```console
nix build
```

Run the packaged PHP interpreter with the extension enabled:

```console
nix run . -- -v
```

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

When startup ordering becomes relevant, place AHE before OPcache:

```ini
zend_extension=/absolute/path/to/abyssal_hyperglyph_engine.so
zend_extension=opcache.so
```

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
