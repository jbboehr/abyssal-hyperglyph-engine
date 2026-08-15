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
            ./src/ahe_opcache_provider.h
            ./src/ahe_php.c
            ./src/abyssal_hyperglyph_engine.c
            ./src/abyssal_hyperglyph_engine.h
            ./tests/001-load.phpt
          ];
        };

        source = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./config.m4
            ./docs/LICENSE_EXCEPTION.md
            ./LICENSE.md
            ./scripts/smoke-test.sh
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
      in {
        packages = {
          default = extension;
          inherit extension;
          ahe-php = aheLauncher;
          php = phpWithAhe;
        };

        apps.default = {
          type = "app";
          program = "${aheLauncher}/bin/ahe-php";
          meta.description = "ASLR-disabled PHP with Abyssal Hyperglyph Engine enabled";
        };

        checks = {
          inherit extension;
          launcher-smoke = launcherSmoke;
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
