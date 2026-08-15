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
      ../config.m4
      ../docs/LICENSE_EXCEPTION.md
      ../docs/architecture.md
      ../flake.lock
      ../flake.nix
      ./checks.nix
      ./packages.nix
      ./sources.nix
      ../patches/php/8.4/0001-external-shared-memory-provider.patch
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
      ../tests/fixtures/concurrent.php
      ../tests/fixtures/persistent.php
      ../tests/fixtures/phpstan-source.php
      ../tests/integration/broker-stall.c
      ../tests/integration/cache-attach.php
      ../tests/integration/cache-create.php
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
