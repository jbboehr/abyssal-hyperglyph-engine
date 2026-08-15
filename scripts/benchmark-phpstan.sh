#!/usr/bin/env bash

set -euo pipefail

readonly phpunit_repository='https://github.com/sebastianbergmann/phpunit.git'
readonly phpunit_tag='12.5.33'
readonly phpunit_commit='b98e028a26c5c5ba7e4a54be96ccf35f2914d184'
readonly -a benchmark_modes=(
  vanilla
  opcache
  opcache-jit
  opcache-jit-function
  ahe
  ahe-jit
  ahe-jit-function
)
readonly -a balanced_mode_offsets=(0 1 6 2 5 3 4)
readonly counterbalance_block_size=${#benchmark_modes[@]}

usage() {
  cat <<'EOF'
Usage: scripts/benchmark-phpstan.sh [--samples COUNT]

Benchmark vanilla PHP, process-local OPcache, and AHE, with and without JIT,
on PHPUnit's PHPStan analysis.
The sample count must be a multiple of 7. The default is
AHE_BENCHMARK_SAMPLES or 7.
EOF
}

samples=${AHE_BENCHMARK_SAMPLES:-7}
while (($#)); do
  case $1 in
    --samples)
      if (($# < 2)); then
        echo "--samples requires a value" >&2
        exit 2
      fi
      samples=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$samples" =~ ^[1-9][0-9]*$ ]]; then
  echo "The sample count must be a positive integer." >&2
  exit 2
fi
if ((samples % counterbalance_block_size != 0)); then
  printf 'The sample count must be a multiple of %s to complete each counterbalancing block.\n' \
    "$counterbalance_block_size" >&2
  exit 2
fi

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
benchmark_ini_directory="$repository_root/benchmarks/phpstan"
vanilla_ini_directory="$benchmark_ini_directory/vanilla"
tracing_jit_ini_directory="$benchmark_ini_directory/jit"
function_jit_ini_directory="$benchmark_ini_directory/jit-function"
probe_script="$benchmark_ini_directory/opcache-status.php"
attachment_probe="$benchmark_ini_directory/require-ahe-attachment.php"
cache_root=${XDG_CACHE_HOME:-${HOME}/.cache}
work_directory=${AHE_BENCHMARK_WORK_DIRECTORY:-$cache_root/abyssal-hyperglyph-engine/benchmarks/phpunit-12.5.33}
checkout_directory="$work_directory/source"
result_root="$work_directory/results"
result_id=$(date -u +%Y%m%dT%H%M%SZ)
result_directory="$result_root/$result_id"

for required_command in ahe-broker ahe-php composer date git; do
  if ! type -P "$required_command" >/dev/null; then
    printf 'Required command not found: %s (run this script from nix develop)\n' "$required_command" >&2
    exit 1
  fi
done

time_binary=$(type -P time || true)
if [[ -z "$time_binary" ]]; then
  echo "GNU time was not found (run this script from nix develop)." >&2
  exit 1
fi

ahe_broker=$(type -P ahe-broker)
ahe_php=$(type -P ahe-php)
# The single-quoted program is PHP, not shell source.
# shellcheck disable=SC2016
base_php_ini_scan_path=$(
  env -u PHP_INI_SCAN_DIR "$ahe_php" -r '
    $scanPath = getenv("PHP_INI_SCAN_DIR");
    if (is_string($scanPath)) {
        echo $scanPath;
    }
  '
)
if [[ -z "$base_php_ini_scan_path" ]]; then
  echo "Could not discover the packaged PHP ini scan directory." >&2
  exit 1
fi
opcache_php_ini_scan_path="$base_php_ini_scan_path:$benchmark_ini_directory"
vanilla_php_ini_scan_path="$opcache_php_ini_scan_path:$vanilla_ini_directory"
tracing_jit_php_ini_scan_path="$opcache_php_ini_scan_path:$tracing_jit_ini_directory"
function_jit_php_ini_scan_path="$opcache_php_ini_scan_path:$function_jit_ini_directory"
mkdir -p "$work_directory" "$result_directory"

if [[ ! -d "$checkout_directory/.git" ]]; then
  if [[ -e "$checkout_directory" ]]; then
    printf 'Benchmark checkout path exists but is not a Git checkout: %s\n' "$checkout_directory" >&2
    exit 1
  fi
  git clone --branch "$phpunit_tag" --depth 1 "$phpunit_repository" "$checkout_directory"
fi

actual_commit=$(git -C "$checkout_directory" rev-parse HEAD)
if [[ "$actual_commit" != "$phpunit_commit" ]]; then
  printf 'Expected PHPUnit commit %s, found %s in %s\n' \
    "$phpunit_commit" "$actual_commit" "$checkout_directory" >&2
  exit 1
fi

assert_clean_checkout() {
  local checkout_status

  checkout_status=$(git -C "$checkout_directory" status --porcelain=v1 --untracked-files=all)
  if [[ -n "$checkout_status" ]]; then
    printf 'The pinned PHPUnit checkout contains local changes:\n%s\n' \
      "$checkout_status" >&2
    echo "Remove them or choose a fresh AHE_BENCHMARK_WORK_DIRECTORY." >&2
    return 1
  fi
}

assert_clean_checkout

composer --working-dir="$checkout_directory" install \
  --no-interaction \
  --no-progress \
  --prefer-dist
assert_clean_checkout
if ! composer --working-dir="$checkout_directory" status --no-interaction --no-ansi; then
  echo "The installed Composer dependencies contain local changes." >&2
  exit 1
fi

if [[ ! -x "$checkout_directory/tools/phpstan" ]]; then
  echo "The pinned PHPUnit checkout does not contain its PHPStan launcher." >&2
  exit 1
fi

runtime_directory=$(mktemp -d /tmp/ahe-phpstan-benchmark.XXXXXX)
broker_socket="$runtime_directory/ahe-broker.sock"
jit_broker_socket="$runtime_directory/ahe-jit-broker.sock"
function_jit_broker_socket="$runtime_directory/ahe-jit-function-broker.sock"
phpstan_tmp_directory="$runtime_directory/phpstan-tmp"
result_cache="$phpstan_tmp_directory/phpstan/phpunit-12.5.php"
result_cache_snapshot="$runtime_directory/phpunit-12.5.snapshot.php"
timing_file="$runtime_directory/timing.tsv"
samples_file="$result_directory/samples.tsv"
primes_file="$result_directory/primes.tsv"
declare -a broker_pids=()
ahe_jit_startup_buffer_free=
ahe_jit_function_startup_buffer_free=

cleanup() {
  local broker_pid

  for broker_pid in "${broker_pids[@]}"; do
    kill "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  done
  if [[ -d "$runtime_directory" && "$runtime_directory" == /tmp/ahe-phpstan-benchmark.* ]]; then
    rm -rf -- "$runtime_directory"
  fi
}
trap cleanup EXIT

declare -a analysis_command

mode_uses_ahe() {
  [[ "$1" == ahe || "$1" == ahe-jit || "$1" == ahe-jit-function ]]
}

build_analysis_command() {
  local mode=$1
  local attachment_directory=${2:-}
  local expect_jit_mode=off
  local mode_php_ini_scan_path=$opcache_php_ini_scan_path
  local -a mode_arguments=("--autoload-file=$attachment_probe")
  analysis_command=(env -C "$checkout_directory")

  case $mode in
    vanilla)
      mode_php_ini_scan_path=$vanilla_php_ini_scan_path
      analysis_command+=(
        -u AHE_BROKER_SOCKET
        -u AHE_CACHE_NAMESPACE
        AHE_BENCHMARK_EXPECT_ATTACHMENT=0
      )
      ;;
    opcache)
      analysis_command+=(
        -u AHE_BROKER_SOCKET
        -u AHE_CACHE_NAMESPACE
        AHE_BENCHMARK_EXPECT_ATTACHMENT=0
      )
      ;;
    opcache-jit)
      mode_php_ini_scan_path=$tracing_jit_php_ini_scan_path
      expect_jit_mode=tracing
      analysis_command+=(
        -u AHE_BROKER_SOCKET
        -u AHE_CACHE_NAMESPACE
        AHE_BENCHMARK_EXPECT_ATTACHMENT=0
      )
      ;;
    opcache-jit-function)
      mode_php_ini_scan_path=$function_jit_php_ini_scan_path
      expect_jit_mode=function
      analysis_command+=(
        -u AHE_BROKER_SOCKET
        -u AHE_CACHE_NAMESPACE
        AHE_BENCHMARK_EXPECT_ATTACHMENT=0
      )
      ;;
    ahe)
      if [[ -z "$attachment_directory" ]]; then
        echo "An AHE analysis requires a fresh attachment-marker directory." >&2
        return 2
      fi
      mkdir "$attachment_directory"
      analysis_command+=(
        "AHE_BROKER_SOCKET=$broker_socket"
        "AHE_CACHE_NAMESPACE=phpunit-$phpunit_commit"
        "AHE_BENCHMARK_ATTACHMENT_DIRECTORY=$attachment_directory"
        AHE_BENCHMARK_EXPECT_ATTACHMENT=1
      )
      ;;
    ahe-jit)
      if [[ -z "$attachment_directory" ]]; then
        echo "An AHE analysis requires a fresh attachment-marker directory." >&2
        return 2
      fi
      mkdir "$attachment_directory"
      mode_php_ini_scan_path=$tracing_jit_php_ini_scan_path
      expect_jit_mode=tracing
      analysis_command+=(
        "AHE_BROKER_SOCKET=$jit_broker_socket"
        "AHE_CACHE_NAMESPACE=phpunit-$phpunit_commit-jit"
        "AHE_BENCHMARK_ATTACHMENT_DIRECTORY=$attachment_directory"
        AHE_BENCHMARK_EXPECT_ATTACHMENT=1
      )
      ;;
    ahe-jit-function)
      if [[ -z "$attachment_directory" ]]; then
        echo "An AHE analysis requires a fresh attachment-marker directory." >&2
        return 2
      fi
      mkdir "$attachment_directory"
      mode_php_ini_scan_path=$function_jit_php_ini_scan_path
      expect_jit_mode=function
      analysis_command+=(
        "AHE_BROKER_SOCKET=$function_jit_broker_socket"
        "AHE_CACHE_NAMESPACE=phpunit-$phpunit_commit-jit-function"
        "AHE_BENCHMARK_ATTACHMENT_DIRECTORY=$attachment_directory"
        AHE_BENCHMARK_EXPECT_ATTACHMENT=1
      )
      ;;
    *)
      printf 'Unknown benchmark mode: %s\n' "$mode" >&2
      return 2
      ;;
  esac

  analysis_command+=(
    "AHE_BENCHMARK_EXPECT_JIT_MODE=$expect_jit_mode"
    "PHP_INI_SCAN_DIR=$mode_php_ini_scan_path"
    "PHPSTAN_TURBO=0"
    "TMPDIR=$phpstan_tmp_directory"
    "$ahe_php" \
    -d "sys_temp_dir='$phpstan_tmp_directory'" \
    tools/phpstan \
    analyse \
    "${mode_arguments[@]}" \
    --error-format=raw \
    --memory-limit=1G \
    --no-progress
  )
}

run_analysis() {
  local mode=$1
  local attachment_directory=${2:-}

  build_analysis_command "$mode" "$attachment_directory"
  "${analysis_command[@]}"
}

verify_ahe_attachments() {
  local attachment_directory=$1
  local parent_count

  parent_count=$(find "$attachment_directory" -maxdepth 1 -type f -name 'parent-*' | wc -l)
  if [[ "$parent_count" -ne 1 ]]; then
    printf 'Expected one attached PHPStan parent, found %s in %s\n' \
      "$parent_count" "$attachment_directory" >&2
    return 1
  fi
}

verify_ahe_cache() {
  local mode=$1
  local report_file=$2
  local jit_startup_buffer_free=
  local mode_broker_socket=$broker_socket
  local mode_cache_namespace=phpunit-$phpunit_commit
  local mode_php_ini_scan_path=$opcache_php_ini_scan_path
  local expect_jit_mode=off

  case $mode in
    ahe) ;;
    ahe-jit)
      mode_broker_socket=$jit_broker_socket
      mode_cache_namespace=phpunit-$phpunit_commit-jit
      mode_php_ini_scan_path=$tracing_jit_php_ini_scan_path
      expect_jit_mode=tracing
      jit_startup_buffer_free=$ahe_jit_startup_buffer_free
      ;;
    ahe-jit-function)
      mode_broker_socket=$function_jit_broker_socket
      mode_cache_namespace=phpunit-$phpunit_commit-jit-function
      mode_php_ini_scan_path=$function_jit_php_ini_scan_path
      expect_jit_mode=function
      jit_startup_buffer_free=$ahe_jit_function_startup_buffer_free
      ;;
    *)
      printf 'Cannot verify a non-AHE benchmark mode: %s\n' "$mode" >&2
      return 2
      ;;
  esac

  env \
    "AHE_BENCHMARK_EXPECT_JIT_MODE=$expect_jit_mode" \
    "AHE_BENCHMARK_JIT_STARTUP_BUFFER_FREE=$jit_startup_buffer_free" \
    "AHE_BROKER_SOCKET=$mode_broker_socket" \
    "AHE_CACHE_NAMESPACE=$mode_cache_namespace" \
    "PHP_INI_SCAN_DIR=$mode_php_ini_scan_path" \
    "$ahe_php" \
    -d "sys_temp_dir='$phpstan_tmp_directory'" \
    "$probe_script" \
    "$checkout_directory" \
    >"$report_file"
}

prepare_result_cache() {
  local cache_state=$1
  case $cache_state in
    cold)
      if [[ -e "$result_cache" ]]; then
        unlink "$result_cache"
      fi
      ;;
    warm)
      cp -- "$result_cache_snapshot" "$result_cache"
      ;;
    *)
      printf 'Unknown result-cache state: %s\n' "$cache_state" >&2
      return 2
      ;;
  esac
}

run_timed() {
  local cache_state=$1
  local mode=$2
  local iteration=$3
  local log_file="$result_directory/$cache_state-$mode-$iteration.log"
  local elapsed_seconds
  local finished_nanoseconds
  local max_rss_kb
  local started_nanoseconds
  local attachment_directory=

  prepare_result_cache "$cache_state"
  if mode_uses_ahe "$mode"; then
    attachment_directory="$runtime_directory/attachments-$cache_state-$mode-$iteration"
  fi
  build_analysis_command "$mode" "$attachment_directory"
  started_nanoseconds=$(date +%s%N)
  if "$time_binary" \
    --output="$timing_file" \
    --format='%M' \
    "${analysis_command[@]}" >"$log_file" 2>&1; then
    finished_nanoseconds=$(date +%s%N)
    if mode_uses_ahe "$mode" && ! verify_ahe_attachments "$attachment_directory"; then
      printf 'The %s/AHE sample %s did not prove attachment; see %s\n' \
        "$cache_state" "$iteration" "$log_file" >&2
      return 1
    fi
    if mode_uses_ahe "$mode" \
      && ! verify_ahe_cache \
        "$mode" \
        "$result_directory/$cache_state-$mode-$iteration-opcache-status.json"; then
      printf 'The %s/AHE sample %s left an unusable shared cache; see %s\n' \
        "$cache_state" "$iteration" "$log_file" >&2
      return 1
    fi
    read -r max_rss_kb <"$timing_file"
    elapsed_seconds=$(awk \
      -v started="$started_nanoseconds" \
      -v finished="$finished_nanoseconds" \
      'BEGIN { printf "%.6f", (finished - started) / 1000000000 }')
  else
    local exit_status=$?
    printf 'PHPStan failed for %s/%s sample %s; see %s\n' \
      "$cache_state" "$mode" "$iteration" "$log_file" >&2
    return "$exit_status"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$cache_state" "$mode" "$iteration" "$elapsed_seconds" "$max_rss_kb" \
    >>"$samples_file"
  printf '%-4s %-20s sample %s: %ss, %s KiB max RSS\n' \
    "$cache_state" "$mode" "$iteration" "$elapsed_seconds" "$max_rss_kb"
}

median_field() {
  local cache_state=$1
  local mode=$2
  local field=$3
  awk -F '\t' -v cache_state="$cache_state" -v mode="$mode" -v field="$field" \
    '$1 == cache_state && $2 == mode { print $field }' "$samples_file" \
    | sort -n \
    | awk '
        { values[NR] = $1 }
        END {
          if (NR % 2 == 1) {
            printf "%.3f", values[(NR + 1) / 2]
          } else {
            printf "%.3f", (values[NR / 2] + values[NR / 2 + 1]) / 2
          }
        }
      '
}

mkdir -p "$phpstan_tmp_directory"
printf 'result_cache\tmode\titeration\telapsed_seconds\tmax_rss_kb\n' >"$samples_file"
printf 'mode\telapsed_seconds\tmax_rss_kb\n' >"$primes_file"
ahe_git_revision=$(git -C "$repository_root" rev-parse HEAD)
ahe_worktree_dirty=0
if [[ -n "$(git -C "$repository_root" status --porcelain=v1 --untracked-files=all)" ]]; then
  ahe_worktree_dirty=1
fi
cpu_model=$(awk -F ': ' '/^model name[[:space:]]*:/{ print $2; exit }' /proc/cpuinfo)
if [[ -z "$cpu_model" ]]; then
  cpu_model=unknown
fi
{
  printf 'result_id=%s\n' "$result_id"
  printf 'phpunit_repository=%s\n' "$phpunit_repository"
  printf 'phpunit_tag=%s\n' "$phpunit_tag"
  printf 'phpunit_commit=%s\n' "$phpunit_commit"
  printf 'php_version=%s\n' \
    "$(PHP_INI_SCAN_DIR="$opcache_php_ini_scan_path" "$ahe_php" -r 'echo PHP_VERSION;')"
  printf 'phpstan_version=%s\n' \
    "$(cd "$checkout_directory" && PHP_INI_SCAN_DIR="$opcache_php_ini_scan_path" PHPSTAN_TURBO=0 "$ahe_php" tools/phpstan --version)"
  printf 'ahe_git_revision=%s\n' "$ahe_git_revision"
  printf 'ahe_worktree_dirty=%s\n' "$ahe_worktree_dirty"
  printf 'system=%s\n' "$(uname -srmo)"
  printf 'cpu_model=%s\n' "$cpu_model"
  printf 'samples_per_cell=%s\n' "$samples"
  printf 'modes=%s\n' "${benchmark_modes[*]}"
  printf 'jit_modes=tracing,function\n'
  printf 'jit_buffer_size=64M\n'
} >"$result_directory/metadata.txt"

effective_settings=$(
  PHP_INI_SCAN_DIR="$opcache_php_ini_scan_path" "$ahe_php" -r '
    printf(
        "%s,%s,%s,%s",
        ini_get("opcache.validate_timestamps"),
        ini_get("opcache.file_update_protection"),
        ini_get("opcache.memory_consumption"),
        ini_get("opcache.max_accelerated_files"),
    );
  '
)
if [[ "$effective_settings" != '0,0,512,100000' ]]; then
  printf 'The benchmark OPcache profile was not loaded (found %s).\n' "$effective_settings" >&2
  exit 1
fi

if ! PHP_INI_SCAN_DIR="$vanilla_php_ini_scan_path" "$ahe_php" -r '
    if (filter_var(ini_get("opcache.enable_cli"), FILTER_VALIDATE_BOOL)) {
        fwrite(STDERR, "Vanilla mode did not disable CLI OPcache.\n");
        exit(1);
    }
  '; then
  exit 1
fi

# The single-quoted program is PHP, not shell source.
# shellcheck disable=SC2016
if ! PHP_INI_SCAN_DIR="$tracing_jit_php_ini_scan_path" "$ahe_php" -r '
    $jit = opcache_get_status(false)["jit"] ?? null;
    if (!is_array($jit)
        || ($jit["enabled"] ?? false) !== true
        || ($jit["on"] ?? false) !== true
        || ($jit["buffer_size"] ?? 0) <= 0
        || ini_get("opcache.jit_buffer_size") !== "64M"
    ) {
        fwrite(STDERR, "JIT mode did not enable the expected 64 MiB tracing buffer.\n");
        exit(1);
    }
  '; then
  exit 1
fi

# The single-quoted program is PHP, not shell source.
# shellcheck disable=SC2016
if ! PHP_INI_SCAN_DIR="$function_jit_php_ini_scan_path" "$ahe_php" -r '
    $jit = opcache_get_status(false)["jit"] ?? null;
    if (!is_array($jit)
        || ($jit["enabled"] ?? false) !== true
        || ($jit["on"] ?? false) !== true
        || ($jit["kind"] ?? null) !== 0
        || ($jit["opt_level"] ?? null) !== 5
        || ($jit["buffer_size"] ?? 0) <= 0
        || ini_get("opcache.jit_buffer_size") !== "64M"
    ) {
        fwrite(STDERR, "Function-JIT mode did not enable the expected 64 MiB buffer.\n");
        exit(1);
    }
  '; then
  exit 1
fi

start_broker() {
  local label=$1
  local socket=$2
  local broker_pid

  "$ahe_broker" --socket "$socket" >"$result_directory/$label-broker.log" 2>&1 &
  broker_pid=$!
  broker_pids+=("$broker_pid")
  for _ in {1..100}; do
    if [[ -S "$socket" ]]; then
      return 0
    fi
    if ! kill -0 "$broker_pid" 2>/dev/null; then
      printf 'The %s broker exited before creating its socket.\n' "$label" >&2
      return 1
    fi
    sleep 0.01
  done
  printf 'The %s broker did not create its socket.\n' "$label" >&2
  return 1
}

capture_ahe_jit_startup_baseline() {
  local output_variable=$1
  local label=$2
  local socket=$3
  local cache_namespace=$4
  local php_ini_scan_path=$5
  local expected_jit_mode=$6
  local buffer_free

  # This first client creates an otherwise empty retained generation. Measuring
  # after JIT startup accounts for the shared stub handlers before PHPStan has
  # had an opportunity to emit workload code.
  # The single-quoted program is PHP, not shell source.
  # shellcheck disable=SC2016
  if ! buffer_free=$(env \
    "AHE_BENCHMARK_EXPECT_JIT_MODE=$expected_jit_mode" \
    "AHE_BROKER_SOCKET=$socket" \
    "AHE_CACHE_NAMESPACE=$cache_namespace" \
    "PHP_INI_SCAN_DIR=$php_ini_scan_path" \
    "$ahe_php" \
    -d "sys_temp_dir='$phpstan_tmp_directory'" \
    -r '
      $status = opcache_get_status(false);
      $jit = is_array($status) ? ($status["jit"] ?? null) : null;
      $maps = file_get_contents("/proc/self/maps");
      $actualJitMode = strtolower((string) ini_get("opcache.jit"));
      $expectedJitMode = (string) getenv("AHE_BENCHMARK_EXPECT_JIT_MODE");
      if (!is_array($jit)
          || ($jit["enabled"] ?? false) !== true
          || ($jit["on"] ?? false) !== true
          || $actualJitMode !== $expectedJitMode
          || !is_int($jit["buffer_size"] ?? null)
          || !is_int($jit["buffer_free"] ?? null)
          || $jit["buffer_free"] <= 0
          || $jit["buffer_free"] >= $jit["buffer_size"]
          || $maps === false
          || !str_contains($maps, "/memfd:ahe-opcache")
      ) {
          fwrite(STDERR, "Could not capture the attached JIT startup baseline.\n");
          exit(1);
      }
      echo $jit["buffer_free"];
    '
  ); then
    return 1
  fi
  if [[ ! "$buffer_free" =~ ^[0-9]+$ ]]; then
    printf 'The %s startup baseline is not an integer: %s\n' \
      "$label" "$buffer_free" >&2
    return 1
  fi

  printf -v "$output_variable" '%s' "$buffer_free"
  printf '%s\n' "$buffer_free" \
    >"$result_directory/$label-startup-buffer-free.txt"
  printf '%s=%s\n' "$output_variable" "$buffer_free" \
    >>"$result_directory/metadata.txt"
}

start_broker ahe "$broker_socket"
start_broker ahe-jit "$jit_broker_socket"
start_broker ahe-jit-function "$function_jit_broker_socket"
capture_ahe_jit_startup_baseline \
  ahe_jit_startup_buffer_free \
  ahe-jit \
  "$jit_broker_socket" \
  "phpunit-$phpunit_commit-jit" \
  "$tracing_jit_php_ini_scan_path" \
  tracing
capture_ahe_jit_startup_baseline \
  ahe_jit_function_startup_buffer_free \
  ahe-jit-function \
  "$function_jit_broker_socket" \
  "phpunit-$phpunit_commit-jit-function" \
  "$function_jit_php_ini_scan_path" \
  function

echo "Priming PHPStan's generated container and result cache..."
if ! run_analysis vanilla '' >"$result_directory/result-cache-prime.log" 2>&1; then
  printf 'The vanilla PHPStan prime failed; see %s\n' \
    "$result_directory/result-cache-prime.log" >&2
  exit 1
fi
if [[ ! -f "$result_cache" ]]; then
  printf 'PHPStan did not create its expected result cache: %s\n' "$result_cache" >&2
  exit 1
fi
cp -- "$result_cache" "$result_cache_snapshot"

run_ahe_prime() {
  local mode=$1
  local prime_attachment_directory="$runtime_directory/attachments-$mode-prime"
  local log_file="$result_directory/$mode-prime.log"
  local elapsed_seconds
  local finished_nanoseconds
  local max_rss_kb
  local started_nanoseconds

  prepare_result_cache cold
  build_analysis_command "$mode" "$prime_attachment_directory"
  started_nanoseconds=$(date +%s%N)
  if ! "$time_binary" \
    --output="$timing_file" \
    --format='%M' \
    "${analysis_command[@]}" >"$log_file" 2>&1; then
    cat <<EOF | tee "$result_directory/failure.txt" >&2
The $mode retained-generation PHPStan prime failed; see:
  $log_file

The retained-generation PHPStan regression failed across independently executed
parent and worker processes. No timing samples were recorded, so this failure
cannot be mistaken for a benchmark result.
EOF
    return 1
  fi
  finished_nanoseconds=$(date +%s%N)
  if ! verify_ahe_attachments "$prime_attachment_directory"; then
    printf 'The %s retained-generation prime did not prove attachment; see %s\n' \
      "$mode" "$log_file" >&2
    return 1
  fi
  if ! verify_ahe_cache "$mode" "$result_directory/$mode-prime-opcache-status.json"; then
    printf 'The %s retained-generation prime left an unusable shared cache.\n' \
      "$mode" >&2
    return 1
  fi
  read -r max_rss_kb <"$timing_file"
  elapsed_seconds=$(awk \
    -v started="$started_nanoseconds" \
    -v finished="$finished_nanoseconds" \
    'BEGIN { printf "%.6f", (finished - started) / 1000000000 }')
  printf '%s\t%s\t%s\n' "$mode" "$elapsed_seconds" "$max_rss_kb" \
    | tee -a "$primes_file"
}

warm_ahe_generation_for_result_cache() {
  local mode=$1
  local attachment_directory="$runtime_directory/attachments-$mode-result-cache-warmup"
  local log_file="$result_directory/$mode-result-cache-warmup.log"

  prepare_result_cache warm
  if ! run_analysis "$mode" "$attachment_directory" >"$log_file" 2>&1; then
    printf 'The %s warm-result-cache transition failed; see %s\n' \
      "$mode" "$log_file" >&2
    return 1
  fi
  if ! verify_ahe_attachments "$attachment_directory"; then
    printf 'The %s warm-result-cache transition did not prove attachment.\n' \
      "$mode" >&2
    return 1
  fi
  verify_ahe_cache \
    "$mode" \
    "$result_directory/$mode-result-cache-warmup-opcache-status.json"
}

echo "Priming the retained AHE generations with result-cache-cold analyses..."
run_ahe_prime ahe
run_ahe_prime ahe-jit
run_ahe_prime ahe-jit-function

for cache_state in cold warm; do
  if [[ "$cache_state" == warm ]]; then
    echo "Warming the retained generations for PHPStan result-cache reuse..."
    warm_ahe_generation_for_result_cache ahe
    warm_ahe_generation_for_result_cache ahe-jit
    warm_ahe_generation_for_result_cache ahe-jit-function
  fi
  for ((iteration = 1; iteration <= samples; iteration++)); do
    for ((order_index = 0; order_index < ${#benchmark_modes[@]}; order_index++)); do
      sequence_index=$order_index
      if ((((iteration - 1) / ${#benchmark_modes[@]}) % 2 == 1)); then
        sequence_index=$((${#benchmark_modes[@]} - order_index - 1))
      fi
      mode_index=$((
        (balanced_mode_offsets[sequence_index] + iteration - 1)
        % ${#benchmark_modes[@]}
      ))
      mode=${benchmark_modes[$mode_index]}
      run_timed "$cache_state" "$mode" "$iteration"
    done
  done
done

summary_file="$result_directory/summary.tsv"
printf 'result_cache\tmode\tmedian_seconds\tspeedup_vs_vanilla_percent\tmedian_rss_kb\n' \
  >"$summary_file"

for cache_state in cold warm; do
  vanilla_seconds=$(median_field "$cache_state" vanilla 4)
  for mode in "${benchmark_modes[@]}"; do
    mode_seconds=$(median_field "$cache_state" "$mode" 4)
    mode_rss=$(median_field "$cache_state" "$mode" 5)
    speedup=$(awk -v baseline="$vanilla_seconds" -v candidate="$mode_seconds" \
      'BEGIN { printf "%.1f", baseline == 0 ? 0 : (baseline - candidate) * 100 / baseline }')
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$cache_state" "$mode" "$mode_seconds" "$speedup" "$mode_rss" \
      | tee -a "$summary_file"
  done
done

comparison_from=(
  vanilla
  opcache
  opcache
  opcache
  ahe
  opcache-jit
  opcache-jit
  opcache-jit-function
  ahe
)
comparison_to=(
  opcache
  opcache-jit
  opcache-jit-function
  ahe
  ahe-jit
  ahe-jit
  opcache-jit-function
  ahe-jit-function
  ahe-jit-function
)
comparisons_file="$result_directory/comparisons.tsv"
printf 'result_cache\tbaseline_mode\tcandidate_mode\tspeedup_percent\n' >"$comparisons_file"
for cache_state in cold warm; do
  for comparison_index in "${!comparison_from[@]}"; do
    baseline_mode=${comparison_from[$comparison_index]}
    candidate_mode=${comparison_to[$comparison_index]}
    baseline_seconds=$(median_field "$cache_state" "$baseline_mode" 4)
    candidate_seconds=$(median_field "$cache_state" "$candidate_mode" 4)
    speedup=$(awk -v baseline="$baseline_seconds" -v candidate="$candidate_seconds" \
      'BEGIN { printf "%.1f", baseline == 0 ? 0 : (baseline - candidate) * 100 / baseline }')
    printf '%s\t%s\t%s\t%s\n' \
      "$cache_state" "$baseline_mode" "$candidate_mode" "$speedup" \
      | tee -a "$comparisons_file"
  done
done

printf 'Raw samples and logs: %s\n' "$result_directory"
