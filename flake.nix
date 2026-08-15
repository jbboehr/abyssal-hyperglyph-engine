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
        sources = import ./nix/sources.nix {inherit lib;};
        ahePackages = import ./nix/packages.nix {
          inherit pkgs lib php sources;
        };
        inherit
          (ahePackages)
          extension
          phpWithAhe
          aheLauncher
          aheBroker
          ;
        aheChecks = import ./nix/checks.nix {
          inherit
            pkgs
            system
            php
            extension
            phpWithAhe
            aheLauncher
            aheBroker
            ;
          preCommitHooks = pre-commit-hooks;
          repositorySource = sources.repository;
        };
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

        checks = aheChecks.checks;

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
            ${aheChecks.preCommitCheck.shellHook}
            export NO_INTERACTION=1
            export REPORT_EXIT_STATUS=1
            export TEST_PHP_EXECUTABLE=${php.unwrapped}/bin/php
          '';
        };

        formatter = pkgs.alejandra;
      }
    );
}
