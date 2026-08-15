{
  pkgs,
  system,
  preCommitHooks,
  repositorySource,
  php,
  extension,
  phpWithAhe,
  aheLauncher,
  aheBroker,
}: let
  phpstanPhar = pkgs.fetchurl {
    url = "https://github.com/phpstan/phpstan/releases/download/2.2.8/phpstan.phar";
    hash = "sha256-q56nJSP+RTufTdGfErHkA6ke+olM0l2bDLPvYrfSC/I=";
  };

  preCommitCheck = preCommitHooks.lib.${system}.run {
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

      if (ini_get("opcache.force_restart_timeout") !== "0") {
        fwrite(STDERR, "The AHE launcher did not disable forced locker termination.\n");
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
    worker_pids=
    ${aheBroker}/bin/ahe-broker --socket "$broker_socket" --max-clients 14 &
    broker_pid=$!

    cleanup_broker() {
      for worker_pid in $worker_pids; do
        kill "$worker_pid" 2>/dev/null || true
        wait "$worker_pid" 2>/dev/null || true
      done
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

    AHE_BROKER_SOCKET="$broker_socket" \
    AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
      ${aheLauncher}/bin/ahe-php \
        -d opcache.force_restart_timeout=1 \
        -r '
          if (opcache_get_status(false) === false) {
            fwrite(STDERR, "OPcache did not fall back for an unsafe forced-restart timeout.\n");
            exit(1);
          }
          $maps = file_get_contents("/proc/self/maps");
          if ($maps === false || str_contains($maps, "/memfd:ahe-opcache")) {
            fwrite(STDERR, "AHE accepted an unsafe forced-restart timeout.\n");
            exit(1);
          }
        '

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
        ${../tests/integration/cache-create.php} \
        ${../tests/fixtures/persistent.php}

    AHE_BROKER_SOCKET="$broker_socket" \
    AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
    AHE_FIXTURE=${../tests/fixtures/persistent.php} \
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
    AHE_FIXTURE=${../tests/fixtures/persistent.php} \
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
    holder_release="$TMPDIR/ahe-holder-release"
    AHE_BROKER_SOCKET="$broker_socket" \
    AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
    AHE_HOLD_MARKER="$hold_marker" \
    AHE_HOLDER_RELEASE="$holder_release" \
      ${aheLauncher}/bin/ahe-php \
        -d opcache.file_update_protection=0 \
        -r '
          file_put_contents((string) getenv("AHE_HOLD_MARKER"), "ready");
          $deadline = microtime(true) + 30;
          while (!is_file((string) getenv("AHE_HOLDER_RELEASE"))) {
            if (microtime(true) >= $deadline) {
              fwrite(STDERR, "The cache holder timed out.\n");
              exit(1);
            }
            usleep(10000);
          }
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

    worker_release="$TMPDIR/ahe-workers-release"
    for worker in {1..8}; do
      worker_marker="$TMPDIR/ahe-worker-$worker-ready"
      AHE_BROKER_SOCKET="$broker_socket" \
      AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
      AHE_PERSISTENT_FIXTURE=${../tests/fixtures/persistent.php} \
      AHE_CONCURRENT_FIXTURE=${../tests/fixtures/concurrent.php} \
      AHE_WORKER_MARKER="$worker_marker" \
      AHE_WORKER_RELEASE="$worker_release" \
        ${aheLauncher}/bin/ahe-php \
          -d opcache.file_update_protection=0 \
          -r '
            $persistentFixture = realpath((string) getenv("AHE_PERSISTENT_FIXTURE"));
            $concurrentFixture = realpath((string) getenv("AHE_CONCURRENT_FIXTURE"));
            if ($persistentFixture === false || $concurrentFixture === false) {
              fwrite(STDERR, "A concurrent worker could not resolve its fixtures.\n");
              exit(1);
            }
            if (!opcache_is_script_cached($persistentFixture)) {
              fwrite(STDERR, "A concurrent worker did not attach to the retained generation.\n");
              exit(1);
            }
            file_put_contents((string) getenv("AHE_WORKER_MARKER"), "ready");
            $deadline = microtime(true) + 30;
            while (!is_file((string) getenv("AHE_WORKER_RELEASE"))) {
              if (microtime(true) >= $deadline) {
                fwrite(STDERR, "A concurrent worker timed out.\n");
                exit(1);
              }
              usleep(10000);
            }
            require $concurrentFixture;
            if (ahe_concurrent_fixture() !== "the cache coordinates writers"
              || !opcache_is_script_cached($concurrentFixture)) {
              fwrite(STDERR, "A concurrent worker could not populate the shared cache.\n");
              exit(1);
            }
          ' &
      worker_pids="$worker_pids $!"
    done

    workers_ready=false
    for attempt in {1..500}; do
      workers_ready=true
      for worker in {1..8}; do
        if [[ ! -f "$TMPDIR/ahe-worker-$worker-ready" ]]; then
          workers_ready=false
          break
        fi
      done
      if [[ "$workers_ready" == true ]]; then
        break
      fi
      sleep 0.01
    done
    if [[ "$workers_ready" != true ]]; then
      echo "The concurrent cache workers did not all attach." >&2
      exit 1
    fi

    touch "$worker_release"
    for worker_pid in $worker_pids; do
      wait "$worker_pid"
    done
    worker_pids=

    touch "$holder_release"
    wait "$holder_pid"
    holder_pid=

    AHE_BROKER_SOCKET="$broker_socket" \
    AHE_CACHE_NAMESPACE="nix-persistence-smoke" \
      ${aheLauncher}/bin/ahe-php \
        -d opcache.file_update_protection=0 \
        ${../tests/integration/cache-attach.php} \
        ${../tests/fixtures/persistent.php} \
        ${../tests/fixtures/concurrent.php}

    wait "$broker_pid"
    trap - EXIT
    touch "$out"
  '';

  classLinkingSmoke =
    pkgs.runCommand "abyssal-hyperglyph-engine-class-linking-smoke" {
      nativeBuildInputs = [
        aheBroker
        aheLauncher
      ];
    } ''
      bash ${repositorySource}/scripts/reproduce-class-linking.sh
      touch "$out"
    '';

  jitReattachmentSmoke =
    pkgs.runCommand "abyssal-hyperglyph-engine-jit-reattachment-smoke" {
      nativeBuildInputs = [
        aheBroker
        aheLauncher
      ];
    } ''
      bash ${repositorySource}/scripts/reproduce-class-linking.sh --jit
      touch "$out"
    '';

  phpstanParallelSmoke = pkgs.runCommand "abyssal-hyperglyph-engine-phpstan-parallel-smoke" {} ''
    broker_socket="$TMPDIR/ahe-broker.sock"
    marker_directory="$TMPDIR/phpstan-markers"
    source_directory="$TMPDIR/phpstan-sources"
    phpstan_tmp_directory="$TMPDIR/phpstan-tmp"
    mkdir "$marker_directory" "$source_directory" "$phpstan_tmp_directory"

    broker_pid=
    cleanup_broker() {
      if [[ -n "''${broker_pid:-}" ]]; then
        kill "$broker_pid" 2>/dev/null || true
        wait "$broker_pid" 2>/dev/null || true
      fi
    }
    trap cleanup_broker EXIT

    for source_number in {1..48}; do
      cp ${../tests/fixtures/phpstan-source.php} \
        "$source_directory/source-$source_number.php"
    done

    ${aheBroker}/bin/ahe-broker --socket "$broker_socket" &
    broker_pid=$!
    for attempt in {1..100}; do
      [[ -S "$broker_socket" ]] && break
      sleep 0.01
    done
    if [[ ! -S "$broker_socket" ]]; then
      echo "The PHPStan smoke-test broker did not create its socket." >&2
      exit 1
    fi

    AHE_BROKER_SOCKET="$broker_socket" \
    AHE_CACHE_NAMESPACE="nix-phpstan-parallel-smoke" \
      ${aheLauncher}/bin/ahe-php \
        ${../tests/integration/cache-create.php} \
        ${../tests/fixtures/persistent.php}

    AHE_BROKER_SOCKET="$broker_socket" \
    AHE_CACHE_NAMESPACE="nix-phpstan-parallel-smoke" \
    AHE_PHPSTAN_MARKER_DIRECTORY="$marker_directory" \
    AHE_PHPSTAN_PERSISTED_FIXTURE=${../tests/fixtures/persistent.php} \
    AHE_PHPSTAN_TMP_DIRECTORY="$phpstan_tmp_directory" \
    PHPSTAN_TURBO=0 \
      ${aheLauncher}/bin/ahe-php \
        ${phpstanPhar} \
        analyse \
        --configuration=${../tests/integration/phpstan.neon} \
        --autoload-file=${../tests/integration/phpstan-worker-bootstrap.php} \
        --memory-limit=512M \
        --no-progress \
        "$source_directory"

    parent_count=$(find "$marker_directory" -maxdepth 1 -type f -name 'parent-*' | wc -l)
    worker_count=$(find "$marker_directory" -maxdepth 1 -type f -name 'worker-*' | wc -l)
    if [[ "$parent_count" -ne 1 || "$worker_count" -lt 1 ]]; then
      echo "PHPStan did not start an attached worker process." >&2
      exit 1
    fi

    kill "$broker_pid"
    wait "$broker_pid"
    broker_pid=
    trap - EXIT
    touch "$out"
  '';

  brokerMultiplexSmoke =
    pkgs.runCommand "abyssal-hyperglyph-engine-broker-multiplex-smoke" {
      nativeBuildInputs = [pkgs.stdenv.cc];
    } ''
      broker_socket="$TMPDIR/ahe-broker.sock"
      stall_marker="$TMPDIR/stall-ready"
      broker_pid=
      stall_pid=

      cleanup_processes() {
        for process_id in "''${stall_pid:-}" "''${broker_pid:-}"; do
          if [[ -n "$process_id" ]]; then
            kill "$process_id" 2>/dev/null || true
            wait "$process_id" 2>/dev/null || true
          fi
        done
      }
      trap cleanup_processes EXIT

      cc -std=c11 -Wall -Wextra -Werror \
        -D_GNU_SOURCE \
        -I${../src} \
        ${../tests/integration/broker-stall.c} \
        -o broker-stall

      ${aheBroker}/bin/ahe-broker --socket "$broker_socket" &
      broker_pid=$!
      for attempt in {1..100}; do
        [[ -S "$broker_socket" ]] && break
        sleep 0.01
      done
      if [[ ! -S "$broker_socket" ]]; then
        echo "The multiplex smoke-test broker did not create its socket." >&2
        exit 1
      fi

      AHE_BROKER_SOCKET="$broker_socket" \
      AHE_CACHE_NAMESPACE="nix-broker-multiplex-smoke" \
        ${aheLauncher}/bin/ahe-php \
          ${../tests/integration/cache-create.php} \
          ${../tests/fixtures/persistent.php}

      ./broker-stall "$broker_socket" "$stall_marker" &
      stall_pid=$!
      for attempt in {1..500}; do
        [[ -f "$stall_marker" ]] && break
        sleep 0.01
      done
      if [[ ! -f "$stall_marker" ]]; then
        echo "The stalled broker client did not reach backpressure." >&2
        exit 1
      fi

      AHE_BROKER_SOCKET="$broker_socket" \
      AHE_CACHE_NAMESPACE="nix-broker-multiplex-smoke" \
      AHE_FIXTURE=${../tests/fixtures/persistent.php} \
        ${aheLauncher}/bin/ahe-php -r '
          $fixture = realpath((string) getenv("AHE_FIXTURE"));
          if ($fixture === false || !opcache_is_script_cached($fixture)) {
            fwrite(STDERR, "A stalled peer prevented an independent cache attachment.\n");
            exit(1);
          }
        '

      kill "$stall_pid" 2>/dev/null || true
      wait "$stall_pid" 2>/dev/null || true
      stall_pid=
      kill "$broker_pid"
      wait "$broker_pid"
      broker_pid=
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
  inherit preCommitCheck;

  checks = {
    inherit extension;
    broker-lifecycle-smoke = brokerLifecycleSmoke;
    broker-multiplex-smoke = brokerMultiplexSmoke;
    class-linking-smoke = classLinkingSmoke;
    jit-reattachment-smoke = jitReattachmentSmoke;
    launcher-smoke = launcherSmoke;
    persistence-smoke = persistenceSmoke;
    phpstan-parallel-smoke = phpstanParallelSmoke;
    pre-commit = preCommitCheck;
    provider-lifetime-smoke = providerLifetimeSmoke;
    wrapper-smoke = wrapperSmoke;
  };
}
