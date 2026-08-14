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

        repositorySource = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./.editorconfig
            ./.envrc
            ./.github/dependabot.yml
            ./.github/workflows/ci.yml
            ./.gitignore
            ./README.md
            ./config.m4
            ./docs/architecture.md
            ./flake.lock
            ./flake.nix
            ./scripts/smoke-test.sh
            ./src/abyssal_hyperglyph_engine.c
            ./src/abyssal_hyperglyph_engine.h
            ./tests/001-load.phpt
          ];
        };

        source = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./config.m4
            ./scripts/smoke-test.sh
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
            license = lib.licenses.agpl3Plus;
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

        phpWithAhe = php.withExtensions ({enabled, ...}: [extension] ++ enabled);

        preCommitCheck = pre-commit-hooks.lib.${system}.run {
          src = repositorySource;
          hooks = {
            actionlint.enable = true;
            alejandra.enable = true;
            markdownlint = {
              enable = true;
              settings.configuration.MD013 = {
                line_length = 1488;
                table = false;
              };
            };
            shellcheck.enable = true;
          };
        };

        wrapperSmoke = pkgs.runCommand "abyssal-hyperglyph-engine-wrapper-smoke" {} ''
          ${phpWithAhe}/bin/php -r '
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
          '
          touch "$out"
        '';
      in {
        packages = {
          default = extension;
          inherit extension;
          php = phpWithAhe;
        };

        apps.default = {
          type = "app";
          program = "${phpWithAhe}/bin/php";
          meta.description = "PHP with Abyssal Hyperglyph Engine enabled";
        };

        checks = {
          inherit extension;
          pre-commit = preCommitCheck;
          wrapper-smoke = wrapperSmoke;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [extension];
          packages = with pkgs; [
            actionlint
            clang-tools
            gdb
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
