{
  pkgs,
  lib,
  php,
  sources,
}: let
  opcacheProviderPatch = ../patches/php/8.4/0001-external-shared-memory-provider.patch;

  extensionBase = php.buildPecl {
    pname = "abyssal_hyperglyph_engine";
    version = "0.1.0-dev";
    src = sources.extension;

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
      opcache.force_restart_timeout=0
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
        ${../src/ahe_php.c} \
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
        -I${../src} \
        ${../src/ahe_broker.c} \
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
in {
  inherit extension phpWithAhe aheLauncher aheBroker;
}
