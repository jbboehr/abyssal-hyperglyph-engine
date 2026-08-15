#!/usr/bin/env bash

set -euo pipefail
ulimit -c 0

readonly fixture_root=/tmp/ahe-jf-

usage() {
  printf 'Usage: %s [--concurrent]\n' "$0"
}

mode=retained
case "${1:-}" in
  "") ;;
  --concurrent) mode=concurrent ;;
  *)
    usage >&2
    exit 2
    ;;
esac
if [[ "$#" -gt 1 ]]; then
  usage >&2
  exit 2
fi

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture_source="$repository_root/tests/fixtures/jit-function.php"
creator_source="$repository_root/tests/integration/jit-function-create.php"
attacher_source="$repository_root/tests/integration/jit-function-attach.php"

for required_command in ahe-broker ahe-php; do
  if ! type -P "$required_command" >/dev/null; then
    printf 'Required command not found: %s (run this script from nix develop)\n' \
      "$required_command" >&2
    exit 1
  fi
done

if [[ -e "$fixture_root" ]]; then
  printf 'The fixed reproducer path already exists: %s\n' "$fixture_root" >&2
  exit 1
fi

runtime_directory=$(mktemp -d /tmp/ahe-jit-function.XXXXXX)
broker_socket="$runtime_directory/broker.sock"
creator_ready="$runtime_directory/creator.ready"
creator_release="$runtime_directory/creator.release"
start_release="$runtime_directory/start.release"
broker_pid=
creator_pid=
worker_pids=()
fixture_root_created=false

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  local worker_pid

  for worker_pid in "${worker_pids[@]}"; do
    kill "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
  done
  if [[ -n "${creator_pid:-}" ]]; then
    kill "$creator_pid" 2>/dev/null || true
    wait "$creator_pid" 2>/dev/null || true
  fi
  if [[ -n "${broker_pid:-}" ]]; then
    kill "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  fi
  if [[ "$fixture_root_created" == true && -d "$fixture_root" ]]; then
    rm -rf -- "$fixture_root"
  fi
  if [[ -d "$runtime_directory" && "$runtime_directory" == /tmp/ahe-jit-function.* ]]; then
    rm -rf -- "$runtime_directory"
  fi
}
trap cleanup EXIT

mkdir -m 0700 "$fixture_root"
fixture_root_created=true
cp "$fixture_source" "$fixture_root/functions.php"
cp "$creator_source" "$fixture_root/creator.php"
cp "$attacher_source" "$fixture_root/attacher.php"

# The single-quoted program is PHP, not shell source.
# shellcheck disable=SC2016
ahe-php \
  -d opcache.enable_cli=0 \
  -d phar.readonly=0 \
  -r '
    $archive = new Phar($argv[1]);
    $archive->startBuffering();
    $archive->addFile($argv[2], "functions.php");
    $archive->setStub("<?php __HALT_COMPILER();");
    $archive->stopBuffering();
  ' \
  "$fixture_root/fixture.phar" \
  "$fixture_source"
export AHE_JIT_FUNCTION_FIXTURE="phar://$fixture_root/fixture.phar/functions.php"

ahe-broker --socket "$broker_socket" >"$runtime_directory/broker.log" 2>&1 &
broker_pid=$!
for _ in {1..100}; do
  if [[ -S "$broker_socket" ]]; then
    break
  fi
  if ! kill -0 "$broker_pid" 2>/dev/null; then
    echo "The whole-function JIT broker exited before creating its socket." >&2
    exit 1
  fi
  sleep 0.01
done
if [[ ! -S "$broker_socket" ]]; then
  echo "The whole-function JIT broker did not create its socket." >&2
  exit 1
fi

export AHE_BROKER_SOCKET="$broker_socket"
export AHE_CACHE_NAMESPACE=jit-function-reproducer

jit_options=(
  -d opcache.file_update_protection=0
  -d opcache.validate_timestamps=0
  -d opcache.jit=function
  -d opcache.jit_buffer_size=64M
)

wait_for_marker() {
  local marker=$1
  local process_pid=$2
  local process_name=$3

  for _ in {1..1000}; do
    if [[ -f "$marker" ]]; then
      return 0
    fi
    if ! kill -0 "$process_pid" 2>/dev/null; then
      printf 'The whole-function JIT %s exited before publishing %s.\n' \
        "$process_name" "$marker" >&2
      wait "$process_pid"
      return 1
    fi
    sleep 0.01
  done
  printf 'The whole-function JIT %s did not publish %s.\n' \
    "$process_name" "$marker" >&2
  return 1
}

if [[ "$mode" == retained ]]; then
  export AHE_JIT_FUNCTION_READY_FILE="$creator_ready"
  export AHE_JIT_FUNCTION_RELEASE_FILE="$creator_release"
  ahe-php "${jit_options[@]}" "$fixture_root/creator.php" &
  creator_pid=$!
  wait_for_marker "$creator_ready" "$creator_pid" creator

  ahe-php "${jit_options[@]}" "$fixture_root/attacher.php"
  touch "$creator_release"
  wait "$creator_pid"
  creator_pid=
else
  export AHE_JIT_FUNCTION_READY_FILE="$creator_ready"
  export AHE_JIT_FUNCTION_RELEASE_FILE="$creator_release"
  ahe-php "${jit_options[@]}" "$fixture_root/creator.php" &
  creator_pid=$!
  wait_for_marker "$creator_ready" "$creator_pid" creator

  for worker_number in {1..8}; do
    worker_ready="$runtime_directory/worker-$worker_number.start-ready"
    AHE_JIT_FUNCTION_START_READY_FILE="$worker_ready" \
    AHE_JIT_FUNCTION_START_RELEASE_FILE="$start_release" \
      ahe-php "${jit_options[@]}" "$fixture_root/attacher.php" &
    worker_pid=$!
    worker_pids+=("$worker_pid")
    wait_for_marker "$worker_ready" "$worker_pid" "worker $worker_number"
  done

  touch "$start_release"
  for worker_pid in "${worker_pids[@]}"; do
    wait "$worker_pid"
  done
  worker_pids=()
  touch "$creator_release"
  wait "$creator_pid"
  creator_pid=
fi
