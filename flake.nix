{
  description = "Abyssal Hyperglyph Engine: Gate of the Adamantine Oath";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    systems.url = "github:nix-systems/default-linux";

    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };

    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
    pre-commit-hooks,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        php = pkgs.php;
        opcacheProviderPatch = ./patches/php/8.4/0001-external-shared-memory-provider.patch;

        repositorySource = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./.editorconfig
            ./.envrc
            ./.gitattributes
            ./.github/dependabot.yml
            ./.github/workflows/ci.yml
            ./.gitignore
            ./LICENSE.md
            ./README.md
            ./config.m4
            ./docs/LICENSE_EXCEPTION.md
            ./docs/architecture.md
            ./flake.lock
            ./flake.nix
            ./patches/php/8.4/0001-external-shared-memory-provider.patch
            ./scripts/smoke-test.sh
            ./src/ahe_broker.c
            ./src/ahe_broker_client.c
            ./src/ahe_broker_client.h
            ./src/ahe_broker_protocol.h
            ./src/ahe_opcache_provider.h
            ./src/ahe_php.c
            ./src/abyssal_hyperglyph_engine.c
            ./src/abyssal_hyperglyph_engine.h
            ./tests/001-load.phpt
            ./tests/fixtures/persistent.php
            ./tests/integration/cache-attach.php
            ./tests/integration/cache-create.php
          ];
        };

        source = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./config.m4
            ./docs/LICENSE_EXCEPTION.md
            ./LICENSE.md
            ./scripts/smoke-test.sh
            ./src/ahe_broker_client.c
            ./src/ahe_broker_client.h
            ./src/ahe_broker_protocol.h
            ./src/ahe_opcache_provider.h
            ./src/abyssal_hyperglyph_engine.c
            ./src/abyssal_hyperglyph_engine.h
            ./tests/001-load.phpt
          ];
        };

        extensionBase = php.buildPecl {
          pname = "abyssal_hyperglyph_engine";
          version = "0.1.0-dev";
          src = source;

          configureFlags = ["--enable-abyssal-hyperglyph-engine"];
          zendExtension = true;

          meta = {
            description = "Experimental Zend extension infrastructure for persistent CLI OPcache";
            license =
              lib.licenses.agpl3Only
              // {
                fullName = "GNU Affero General Public License v3.0 only with the Romic Exception";
                shortName = "agpl3OnlyWithRomicException";
                spdxId = "AGPL-3.0-only WITH romic-exception";
                url = "https://spdx.org/licenses/romic-exception.html";
              };
            platforms = lib.platforms.linux;
          };
        };

        extension = extensionBase.overrideAttrs (_: {
          doCheck = true;
          checkPhase = ''
            runHook preCheck

            extension_path="$PWD/modules/abyssal_hyperglyph_engine.so"
            TEST_PHP_EXECUTABLE=${php.unwrapped}/bin/php \
              bash scripts/smoke-test.sh "$extension_path"
            ${php.unwrapped}/bin/php -n run-tests.php \
              -q -n -d "zend_extension=$extension_path" tests

            runHook postCheck
          '';
        });

        phpWithAhe = php.buildEnv {
          extensions = {enabled, ...}: let
            patchedEnabled =
              map (
                candidate:
                  if candidate.extensionName == "opcache"
                  then
                    candidate.overrideAttrs (old: {
                      patches = (old.patches or []) ++ [opcacheProviderPatch];
                    })
                  else candidate
              )
              enabled;
          in
            [extension] ++ patchedEnabled;

          extraConfig = ''
            opcache.enable_cli=1
            opcache.jit=disable
            opcache.jit_buffer_size=0
          '';
        };

        aheLauncher = pkgs.stdenv.mkDerivation {
          pname = "ahe-php";
          version = "0.1.0-dev";
          dontUnpack = true;
          strictDeps = true;

          buildPhase = ''
            runHook preBuild

            $CC -std=c11 -Wall -Wextra -Werror \
              -D_GNU_SOURCE \
              -DAHE_PHP_BINARY='"${phpWithAhe}/bin/php"' \
              ${./src/ahe_php.c} \
              -o ahe-php

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            install -D -m 0755 ahe-php "$out/bin/ahe-php"

            runHook postInstall
          '';

          meta =
            extension.meta
            // {
              description = "ASLR-disabled PHP launcher for Abyssal Hyperglyph Engine";
              mainProgram = "ahe-php";
            };
        };

        aheBroker = pkgs.stdenv.mkDerivation {
          pname = "ahe-broker";
          version = "0.1.0-dev";
          dontUnpack = true;
          strictDeps = true;

          buildPhase = ''
            runHook preBuild

            $CC -std=c11 -Wall -Wextra -Werror \
              -D_GNU_SOURCE \
              -I${./src} \
              ${./src/ahe_broker.c} \
              -o ahe-broker

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            install -D -m 0755 ahe-broker "$out/bin/ahe-broker"

            runHook postInstall
          '';

          meta =
            extension.meta
            // {
              description = "Shared-memory broker for Abyssal Hyperglyph Engine";
              mainProgram = "ahe-broker";
            };
        };

        preCommitCheck = pre-commit-hooks.lib.${system}.run {
          src = repositorySource;
          hooks = {
            actionlint.enable = true;
            alejandra.enable = true;
            markdownlint = {
              enable = true;
              excludes = ["LICENSE\\.md"];
              settings.configuration.MD013 = {
                line_length = 1488;
                table = false;
              };
            };
            shellcheck.enable = true;
          };
        };

        wrapperSmoke = pkgs.runCommand "abyssal-hyperglyph-engine-wrapper-smoke" {} ''
          ${phpWithAhe}/bin/php -d opcache.enable_cli=1 -r '
            $zendExtensions = get_loaded_extensions(true);
            $ahe = array_search(
              "Abyssal Hyperglyph Engine: Gate of the Adamantine Oath",
              $zendExtensions,
              true
            );
            $opcache = array_search("Zend OPcache", $zendExtensions, true);

            if (!extension_loaded("openssl")) {
              fwrite(STDERR, "The wrapped PHP interpreter lost OpenSSL.\n");
              exit(1);
            }

            if ($ahe === false || $opcache === false || $ahe >= $opcache) {
              fwrite(STDERR, "AHE must load before Zend OPcache.\n");
              exit(1);
            }

            if (opcache_get_status(false) === false) {
              fwrite(STDERR, "OPcache did not initialize after AHE declined the provider.\n");
              exit(1);
            }
          '
          touch "$out"
        '';

        launcherSmoke = pkgs.runCommand "abyssal-hyperglyph-engine-launcher-smoke" {} ''
          ${aheLauncher}/bin/ahe-php -r '
            $personality = hexdec(trim(file_get_contents("/proc/self/personality")));

            if (($personality & 0x40000) === 0) {
              fwrite(STDERR, "The AHE launcher did not disable ASLR.\n");
              exit(1);
            }

            if (getenv("AHE_EXPECT_NO_ASLR") !== "1") {
              fwrite(STDERR, "The AHE launcher contract marker is missing.\n");
              exit(1);
            }

            if (!in_array(
              "Abyssal Hyperglyph Engine: Gate of the Adamantine Oath",
              get_loaded_extensions(true),
              true
            )) {
              fwrite(STDERR, "AHE did not survive Zend startup.\n");
              exit(1);
            }
          '
          touch "$out"
        '';

        providerLifetimeSmoke = pkgs.runCommand "abyssal-hyperglyph-engine-provider-lifetime-smoke" {} ''
          AHE_EXPECT_NO_ASLR=1 ${phpWithAhe}/bin/php -r '
            $personality = hexdec(trim(file_get_contents("/proc/self/personality")));
            $aheLoaded = in_array(
              "Abyssal Hyperglyph Engine: Gate of the Adamantine Oath",
              get_loaded_extensions(true),
              true
            );

            if (($personality & 0x40000) === 0 && $aheLoaded) {
              fwrite(STDERR, "AHE unexpectedly survived a failed ASLR contract.\n");
              exit(1);
            }

            if (opcache_get_status(false) === false) {
              fwrite(STDERR, "OPcache did not survive AHE startup failure.\n");
              exit(1);
            }
          '
          touch "$out"
        '';

        persistenceSmoke = pkgs.runCommand "abyssal-hyperglyph-engine-persistence-smoke" {} ''
          broker_socket="$TMPDIR/ahe-broker.sock"
          holder_pid=
          ${aheBroker}/bin/ahe-broker --socket "$broker_socket" --max-clients 7 &
          broker_pid=$!

          cleanup_broker() {
            if [[ -n "''${holder_pid:-}" ]]; then
              kill "$holder_pid" 2>/dev/null || true
              wait "$holder_pid" 2>/dev/null || true
            fi
            kill "$broker_pid" 2>/dev/null || true
            wait "$broker_pid" 2>/dev/null || true
          }
          trap cleanup_broker EXIT

          for attempt in {1..100}; do
            if [[ -S "$broker_socket" ]]; then
              break
            fi
            sleep 0.01
          done
          if [[ ! -S "$broker_socket" ]]; then
            echo "The AHE broker did not create its socket." >&2
            exit 1
          fi

          if AHE_BROKER_SOCKET="$broker_socket" \
            AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
              ${aheLauncher}/bin/ahe-php \
                -d opcache.preload=/definitely/missing/ahe-preload.php \
                -r 'exit(0);'; then
            echo "The deliberately broken creator unexpectedly succeeded." >&2
            exit 1
          fi

          AHE_BROKER_SOCKET="$broker_socket" \
          AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
            ${aheLauncher}/bin/ahe-php \
              -d opcache.file_update_protection=0 \
              ${./tests/integration/cache-create.php} \
              ${./tests/fixtures/persistent.php}

          AHE_BROKER_SOCKET="$broker_socket" \
          AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
          AHE_FIXTURE=${./tests/fixtures/persistent.php} \
            ${aheLauncher}/bin/ahe-php \
              -d opcache.file_update_protection=0 \
              -d opcache.interned_strings_buffer=16 \
              -r '
                $fixture = realpath((string) getenv("AHE_FIXTURE"));
                if ($fixture === false || opcache_get_status(false) === false) {
                  fwrite(STDERR, "OPcache did not fall back for a layout mismatch.\n");
                  exit(1);
                }
                if (opcache_is_script_cached($fixture)) {
                  fwrite(STDERR, "The layout-mismatched process attached to the retained generation.\n");
                  exit(1);
                }
              '

          AHE_BROKER_SOCKET="$broker_socket" \
          AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
          AHE_FIXTURE=${./tests/fixtures/persistent.php} \
            ${aheLauncher}/bin/ahe-php \
              -d opcache.file_update_protection=0 \
              -d opcache.memory_consumption=256 \
              -r '
                $fixture = realpath((string) getenv("AHE_FIXTURE"));
                if ($fixture === false || opcache_get_status(false) === false) {
                  fwrite(STDERR, "OPcache did not fall back for an incompatible cache key.\n");
                  exit(1);
                }
                if (opcache_is_script_cached($fixture)) {
                  fwrite(STDERR, "The size-mismatched process attached to the retained generation.\n");
                  exit(1);
                }
              '

          hold_marker="$TMPDIR/ahe-holder-ready"
          AHE_BROKER_SOCKET="$broker_socket" \
          AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
          AHE_HOLD_MARKER="$hold_marker" \
            ${aheLauncher}/bin/ahe-php \
              -d opcache.file_update_protection=0 \
              -r '
                file_put_contents((string) getenv("AHE_HOLD_MARKER"), "ready");
                sleep(3);
              ' &
          holder_pid=$!

          for attempt in {1..100}; do
            if [[ -f "$hold_marker" ]]; then
              break
            fi
            sleep 0.01
          done
          if [[ ! -f "$hold_marker" ]]; then
            echo "The cache-holding PHP process did not start." >&2
            exit 1
          fi

          AHE_BROKER_SOCKET="$broker_socket" \
          AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
          AHE_FIXTURE=${./tests/fixtures/persistent.php} \
            ${aheLauncher}/bin/ahe-php \
              -d opcache.file_update_protection=0 \
              -r '
                $fixture = realpath((string) getenv("AHE_FIXTURE"));
                if ($fixture === false || opcache_get_status(false) === false) {
                  fwrite(STDERR, "The contending process did not fall back to local OPcache.\n");
                  exit(1);
                }
                if (opcache_is_script_cached($fixture)) {
                  fwrite(STDERR, "The contending process unexpectedly attached to the busy broker.\n");
                  exit(1);
                }
              '

          wait "$holder_pid"
          holder_pid=

          AHE_BROKER_SOCKET="$broker_socket" \
          AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
            ${aheLauncher}/bin/ahe-php \
              -d opcache.file_update_protection=0 \
              ${./tests/integration/cache-attach.php} \
              ${./tests/fixtures/persistent.php}

          wait "$broker_pid"
          trap - EXIT
          touch "$out"
        '';

        brokerLifecycleSmoke = pkgs.runCommand "abyssal-hyperglyph-engine-broker-lifecycle-smoke" {} ''
          broker_pid=
          php_pid=
          watchdog_pid=

          cleanup_processes() {
            for process_id in "''${php_pid:-}" "''${broker_pid:-}" "''${watchdog_pid:-}"; do
              if [[ -n "$process_id" ]]; then
                kill "$process_id" 2>/dev/null || true
                wait "$process_id" 2>/dev/null || true
              fi
            done
          }
          trap cleanup_processes EXIT

          insecure_directory="$TMPDIR/insecure"
          mkdir "$insecure_directory"
          chmod 0777 "$insecure_directory"
          if ${aheBroker}/bin/ahe-broker \
            --socket "$insecure_directory/broker.sock" \
            --max-clients 1; then
            echo "The broker accepted an unsafe parent directory." >&2
            exit 1
          fi

          broker_socket="$TMPDIR/lifecycle/ahe-broker.sock"
          hold_marker="$TMPDIR/lifecycle-holder-ready"
          ${aheBroker}/bin/ahe-broker --socket "$broker_socket" &
          broker_pid=$!
          for attempt in {1..100}; do
            [[ -S "$broker_socket" ]] && break
            sleep 0.01
          done
          if [[ ! -S "$broker_socket" ]]; then
            echo "The lifecycle broker did not create its socket." >&2
            exit 1
          fi

          AHE_BROKER_SOCKET="$broker_socket" \
          AHE_CACHE_NAMESPACE="nix-lifecycle-smoke" \
          AHE_HOLD_MARKER="$hold_marker" \
            ${aheLauncher}/bin/ahe-php -r '
              file_put_contents((string) getenv("AHE_HOLD_MARKER"), "ready");
              sleep(30);
            ' &
          php_pid=$!
          for attempt in {1..100}; do
            [[ -f "$hold_marker" ]] && break
            sleep 0.01
          done
          if [[ ! -f "$hold_marker" ]]; then
            echo "The lifecycle client did not reach user code." >&2
            exit 1
          fi

          kill -TERM "$broker_pid"
          timeout_marker="$TMPDIR/broker-shutdown-timed-out"
          (
            sleep 2
            touch "$timeout_marker"
            kill -KILL "$broker_pid" 2>/dev/null || true
          ) &
          watchdog_pid=$!
          wait "$broker_pid" || true
          broker_pid=
          kill "$watchdog_pid" 2>/dev/null || true
          wait "$watchdog_pid" 2>/dev/null || true
          watchdog_pid=
          if [[ -e "$timeout_marker" ]]; then
            echo "The broker ignored SIGTERM while a client was connected." >&2
            exit 1
          fi
          kill "$php_pid" 2>/dev/null || true
          wait "$php_pid" 2>/dev/null || true
          php_pid=

          ${aheBroker}/bin/ahe-broker --socket "$broker_socket" &
          broker_pid=$!
          for attempt in {1..100}; do
            [[ -S "$broker_socket" ]] && break
            sleep 0.01
          done
          kill -KILL "$broker_pid"
          wait "$broker_pid" 2>/dev/null || true
          broker_pid=
          if [[ ! -S "$broker_socket" ]]; then
            echo "The forced broker exit did not leave a socket for the restart test." >&2
            exit 1
          fi
          if grep -Fq -- "$broker_socket" /proc/net/unix; then
            echo "The killed broker unexpectedly retained a live Unix socket." >&2
            exit 1
          fi

          ${aheBroker}/bin/ahe-broker --socket "$broker_socket" --max-clients 1 &
          broker_pid=$!
          replacement_ready=false
          for attempt in {1..100}; do
            if [[ -S "$broker_socket" ]] \
              && grep -Fq -- "$broker_socket" /proc/net/unix; then
              replacement_ready=true
              break
            fi
            sleep 0.01
          done
          if [[ "$replacement_ready" != true ]]; then
            echo "The broker did not recover its stale socket." >&2
            exit 1
          fi

          chmod 0666 "$broker_socket"
          AHE_BROKER_SOCKET="$broker_socket" \
          AHE_CACHE_NAMESPACE="nix-lifecycle-smoke" \
            ${aheLauncher}/bin/ahe-php -r '
              if (opcache_get_status(false) === false) {
                fwrite(STDERR, "OPcache did not fall back for an unsafe broker socket.\n");
                exit(1);
              }
            '
          chmod 0600 "$broker_socket"

          AHE_BROKER_SOCKET="$broker_socket" \
          AHE_CACHE_NAMESPACE="nix-lifecycle-smoke" \
            ${aheLauncher}/bin/ahe-php -r 'exit(0);'
          wait "$broker_pid"
          broker_pid=

          trap - EXIT
          touch "$out"
        '';
      in {
        packages = {
          default = extension;
          inherit extension;
          ahe-broker = aheBroker;
          ahe-php = aheLauncher;
          php = phpWithAhe;
        };

        apps.default = {
          type = "app";
          program = "${aheLauncher}/bin/ahe-php";
          meta.description = "ASLR-disabled PHP with Abyssal Hyperglyph Engine enabled";
        };

        apps.broker = {
          type = "app";
          program = "${aheBroker}/bin/ahe-broker";
          meta.description = "Shared-memory broker for Abyssal Hyperglyph Engine";
        };

        checks = {
          inherit extension;
          broker-lifecycle-smoke = brokerLifecycleSmoke;
          launcher-smoke = launcherSmoke;
          persistence-smoke = persistenceSmoke;
          pre-commit = preCommitCheck;
          provider-lifetime-smoke = providerLifetimeSmoke;
          wrapper-smoke = wrapperSmoke;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [extension];
          packages = with pkgs; [
            actionlint
            clang-tools
            gdb
            aheBroker
            aheLauncher
            phpWithAhe
            php.unwrapped.dev
            valgrind
          ];

          shellHook = ''
            ${preCommitCheck.shellHook}
            export NO_INTERACTION=1
            export REPORT_EXIT_STATUS=1
            export TEST_PHP_EXECUTABLE=${php.unwrapped}/bin/php
          '';
        };

        formatter = pkgs.alejandra;
      }
    );
}
