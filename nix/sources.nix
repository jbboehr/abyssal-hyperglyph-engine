{lib}: let
  root = ./..;
in {
  repository = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      ../.editorconfig
      ../.envrc
      ../.gitattributes
      ../.github/dependabot.yml
      ../.github/workflows/ci.yml
      ../.gitignore
      ../LICENSE.md
      ../README.md
      ../benchmarks/phpstan/README.md
      ../benchmarks/phpstan/jit-function/opcache.ini
      ../benchmarks/phpstan/jit/opcache.ini
      ../benchmarks/phpstan/opcache-status.php
      ../benchmarks/phpstan/opcache.ini
      ../benchmarks/phpstan/require-ahe-attachment.php
      ../benchmarks/phpstan/vanilla/opcache.ini
      ../config.m4
      ../docs/LICENSE_EXCEPTION.md
      ../docs/architecture.md
      ../docs/development/phpstan-benchmarks.md
      ../flake.lock
      ../flake.nix
      ./checks.nix
      ./packages.nix
      ./sources.nix
      ../patches/php/8.4/0001-external-shared-memory-provider.patch
      ../patches/php/8.4/0002-enable-shm-reattachment.patch
      ../scripts/benchmark-phpstan.sh
      ../scripts/reproduce-class-linking.sh
      ../scripts/smoke-test.sh
      ../src/ahe_broker.c
      ../src/ahe_broker_client.c
      ../src/ahe_broker_client.h
      ../src/ahe_broker_protocol.h
      ../src/ahe_opcache_provider.h
      ../src/ahe_php.c
      ../src/abyssal_hyperglyph_engine.c
      ../src/abyssal_hyperglyph_engine.h
      ../tests/001-load.phpt
      ../tests/fixtures/class-linking.php
      ../tests/fixtures/concurrent.php
      ../tests/fixtures/persistent.php
      ../tests/fixtures/phpstan-source.php
      ../tests/integration/broker-stall.c
      ../tests/integration/cache-attach.php
      ../tests/integration/cache-create.php
      ../tests/integration/class-linking-attach.php
      ../tests/integration/class-linking-create.php
      ../tests/integration/phpstan-worker-bootstrap.php
      ../tests/integration/phpstan.neon
    ];
  };

  extension = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      ../config.m4
      ../docs/LICENSE_EXCEPTION.md
      ../LICENSE.md
      ../scripts/smoke-test.sh
      ../src/ahe_broker_client.c
      ../src/ahe_broker_client.h
      ../src/ahe_broker_protocol.h
      ../src/ahe_opcache_provider.h
      ../src/abyssal_hyperglyph_engine.c
      ../src/abyssal_hyperglyph_engine.h
      ../tests/001-load.phpt
    ];
  };
}
