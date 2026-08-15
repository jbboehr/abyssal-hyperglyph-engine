#!/usr/bin/env bash

set -euo pipefail

readonly phpunit_repository='https://github.com/sebastianbergmann/phpunit.git'
readonly phpunit_tag='12.5.33'
readonly phpunit_commit='b98e028a26c5c5ba7e4a54be96ccf35f2914d184'

usage() {
  cat <<'EOF'
Usage: scripts/benchmark-phpstan.sh [--samples COUNT]

Benchmark process-local OPcache against AHE on PHPUnit's PHPStan analysis.
The default sample count is AHE_BENCHMARK_SAMPLES or 5.
EOF
}

samples=${AHE_BENCHMARK_SAMPLES:-5}
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

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
benchmark_ini_directory="$repository_root/benchmarks/phpstan"
probe_script="$benchmark_ini_directory/opcache-status.php"
attachment_probe="$benchmark_ini_directory/require-ahe-attachment.php"
cache_root=${XDG_CACHE_HOME:-${HOME}/.cache}
work_directory=${AHE_BENCHMARK_WORK_DIRECTORY:-$cache_root/abyssal-hyperglyph-engine/benchmarks/phpunit-12.5.33}
checkout_directory="$work_directory/source"
result_root="$work_directory/results"
result_directory="$result_root/$(date -u +%Y%m%dT%H%M%SZ)"

for required_command in ahe-broker ahe-php composer git; do
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
  "$ahe_php" -r '
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
php_ini_scan_path="$base_php_ini_scan_path:$benchmark_ini_directory"
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
broker_socket="$runtime_directory/broker.sock"
phpstan_tmp_directory="$runtime_directory/phpstan-tmp"
result_cache="$phpstan_tmp_directory/phpstan/phpunit-12.5.php"
result_cache_snapshot="$runtime_directory/phpunit-12.5.snapshot.php"
timing_file="$runtime_directory/timing.tsv"
samples_file="$result_directory/samples.tsv"
broker_pid=

cleanup() {
  if [[ -n "${broker_pid:-}" ]]; then
    kill "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  fi
  if [[ -d "$runtime_directory" && "$runtime_directory" == /tmp/ahe-phpstan-benchmark.* ]]; then
    rm -rf -- "$runtime_directory"
  fi
}
trap cleanup EXIT

declare -a analysis_command

build_analysis_command() {
  local mode=$1
  local attachment_directory=${2:-}
  local -a mode_arguments=("--autoload-file=$attachment_probe")
  analysis_command=(env -C "$checkout_directory")

  case $mode in
    baseline)
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
    *)
      printf 'Unknown benchmark mode: %s\n' "$mode" >&2
      return 2
      ;;
  esac

  analysis_command+=(
    "PHP_INI_SCAN_DIR=$php_ini_scan_path"
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
  local report_file=$1

  env \
    "AHE_BROKER_SOCKET=$broker_socket" \
    "AHE_CACHE_NAMESPACE=phpunit-$phpunit_commit" \
    "PHP_INI_SCAN_DIR=$php_ini_scan_path" \
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
  local max_rss_kb
  local attachment_directory=

  prepare_result_cache "$cache_state"
  if [[ "$mode" == ahe ]]; then
    attachment_directory="$runtime_directory/attachments-$cache_state-$iteration"
  fi
  build_analysis_command "$mode" "$attachment_directory"
  if "$time_binary" \
    --output="$timing_file" \
    --format=$'%e\t%M' \
    "${analysis_command[@]}" >"$log_file" 2>&1; then
    if [[ "$mode" == ahe ]] && ! verify_ahe_attachments "$attachment_directory"; then
      printf 'The %s/AHE sample %s did not prove attachment; see %s\n' \
        "$cache_state" "$iteration" "$log_file" >&2
      return 1
    fi
    if [[ "$mode" == ahe ]] \
      && ! verify_ahe_cache "$result_directory/$cache_state-ahe-$iteration-opcache-status.json"; then
      printf 'The %s/AHE sample %s left an unusable shared cache; see %s\n' \
        "$cache_state" "$iteration" "$log_file" >&2
      return 1
    fi
    read -r elapsed_seconds max_rss_kb <"$timing_file"
  else
    local exit_status=$?
    printf 'PHPStan failed for %s/%s sample %s; see %s\n' \
      "$cache_state" "$mode" "$iteration" "$log_file" >&2
    return "$exit_status"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$cache_state" "$mode" "$iteration" "$elapsed_seconds" "$max_rss_kb" \
    >>"$samples_file"
  printf '%-4s %-8s sample %s: %ss, %s KiB max RSS\n' \
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
{
  printf 'phpunit_repository=%s\n' "$phpunit_repository"
  printf 'phpunit_tag=%s\n' "$phpunit_tag"
  printf 'phpunit_commit=%s\n' "$phpunit_commit"
  printf 'php_version=%s\n' "$("$ahe_php" -r 'echo PHP_VERSION;')"
  printf 'phpstan_version=%s\n' "$(cd "$checkout_directory" && PHPSTAN_TURBO=0 "$ahe_php" tools/phpstan --version)"
  printf 'samples_per_cell=%s\n' "$samples"
} >"$result_directory/metadata.txt"

effective_settings=$(
  PHP_INI_SCAN_DIR="$php_ini_scan_path" "$ahe_php" -r '
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

"$ahe_broker" --socket "$broker_socket" >"$result_directory/broker.log" 2>&1 &
broker_pid=$!
for _ in {1..100}; do
  if [[ -S "$broker_socket" ]]; then
    break
  fi
  if ! kill -0 "$broker_pid" 2>/dev/null; then
    echo "The AHE broker exited before creating its socket." >&2
    exit 1
  fi
  sleep 0.01
done
if [[ ! -S "$broker_socket" ]]; then
  echo "The AHE broker did not create its socket." >&2
  exit 1
fi

echo "Priming PHPStan's generated container and result cache..."
if ! run_analysis baseline '' >"$result_directory/result-cache-prime.log" 2>&1; then
  printf 'The process-local PHPStan prime failed; see %s\n' \
    "$result_directory/result-cache-prime.log" >&2
  exit 1
fi
if [[ ! -f "$result_cache" ]]; then
  printf 'PHPStan did not create its expected result cache: %s\n' "$result_cache" >&2
  exit 1
fi
cp -- "$result_cache" "$result_cache_snapshot"

echo "Priming the retained AHE generation with a result-cache-cold analysis..."
prepare_result_cache cold
prime_attachment_directory="$runtime_directory/attachments-ahe-prime"
if ! run_analysis ahe "$prime_attachment_directory" >"$result_directory/ahe-prime.log" 2>&1; then
  cat <<EOF | tee "$result_directory/failure.txt" >&2
The retained-generation PHPStan prime failed; see:
  $result_directory/ahe-prime.log

The retained-generation PHPStan regression failed across independently executed
parent and worker processes. No timing samples were recorded, so this failure
cannot be mistaken for a benchmark result.
EOF
  exit 1
fi
if ! verify_ahe_attachments "$prime_attachment_directory"; then
  printf 'The retained-generation prime did not prove attachment; see %s\n' \
    "$result_directory/ahe-prime.log" >&2
  exit 1
fi

verify_ahe_cache "$result_directory/opcache-status.json"

for cache_state in cold warm; do
  for ((iteration = 1; iteration <= samples; iteration++)); do
    if ((iteration % 2 == 1)); then
      run_timed "$cache_state" baseline "$iteration"
      run_timed "$cache_state" ahe "$iteration"
    else
      run_timed "$cache_state" ahe "$iteration"
      run_timed "$cache_state" baseline "$iteration"
    fi
  done
done

summary_file="$result_directory/summary.tsv"
printf 'result_cache\tbaseline_median_seconds\tahe_median_seconds\tspeedup_percent\tbaseline_median_rss_kb\tahe_median_rss_kb\n' \
  >"$summary_file"

for cache_state in cold warm; do
  baseline_seconds=$(median_field "$cache_state" baseline 4)
  ahe_seconds=$(median_field "$cache_state" ahe 4)
  baseline_rss=$(median_field "$cache_state" baseline 5)
  ahe_rss=$(median_field "$cache_state" ahe 5)
  speedup=$(awk -v baseline="$baseline_seconds" -v ahe="$ahe_seconds" \
    'BEGIN { printf "%.1f", baseline == 0 ? 0 : (baseline - ahe) * 100 / baseline }')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$cache_state" "$baseline_seconds" "$ahe_seconds" "$speedup" "$baseline_rss" "$ahe_rss" \
    | tee -a "$summary_file"
done

printf 'Raw samples and logs: %s\n' "$result_directory"
