#!/usr/bin/env bash

set -euo pipefail
ulimit -c 0

readonly fixture_root=/tmp/ahe-r-

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture_source="$repository_root/tests/fixtures/class-linking.php"
creator_source="$repository_root/tests/integration/class-linking-create.php"
attacher_source="$repository_root/tests/integration/class-linking-attach.php"
jit_options=()
php_arguments=()

case "${1:-}" in
  "") ;;
  --jit)
    jit_options=(
      -d opcache.jit=tracing
      -d opcache.jit_buffer_size=64M
      -d opcache.jit_hot_func=0
      -d opcache.jit_hot_loop=1
    )
    php_arguments=(--jit)
    ;;
  *)
    printf 'Usage: %s [--jit]\n' "$0" >&2
    exit 2
    ;;
esac
if [[ "$#" -gt 1 ]]; then
  printf 'Usage: %s [--jit]\n' "$0" >&2
  exit 2
fi

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

runtime_directory=$(mktemp -d /tmp/ahe-class-linking.XXXXXX)
broker_socket="$runtime_directory/broker.sock"
broker_pid=
fixture_root_created=false

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  if [[ -n "${broker_pid:-}" ]]; then
    kill "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  fi
  if [[ "$fixture_root_created" == true && -d "$fixture_root" ]]; then
    rm -rf -- "$fixture_root"
  fi
  if [[ -d "$runtime_directory" && "$runtime_directory" == /tmp/ahe-class-linking.* ]]; then
    rm -rf -- "$runtime_directory"
  fi
}
trap cleanup EXIT

mkdir -m 0700 "$fixture_root"
fixture_root_created=true
mkdir "$fixture_root/classes"
cp "$fixture_source" "$fixture_root/classes/Lookahead.php"
cp "$creator_source" "$fixture_root/creator.php"
cp "$attacher_source" "$fixture_root/attacher.php"

ahe-broker --socket "$broker_socket" >"$runtime_directory/broker.log" 2>&1 &
broker_pid=$!
for _ in {1..100}; do
  if [[ -S "$broker_socket" ]]; then
    break
  fi
  if ! kill -0 "$broker_pid" 2>/dev/null; then
    echo "The class-linking broker exited before creating its socket." >&2
    exit 1
  fi
  sleep 0.01
done
if [[ ! -S "$broker_socket" ]]; then
  echo "The class-linking broker did not create its socket." >&2
  exit 1
fi

export AHE_BROKER_SOCKET="$broker_socket"
export AHE_CACHE_NAMESPACE=class-linking-reproducer

ahe-php \
  "${jit_options[@]}" \
  -d opcache.file_update_protection=0 \
  "$fixture_root/creator.php" \
  "${php_arguments[@]}"

set +e
ahe-php \
  "${jit_options[@]}" \
  -d opcache.file_update_protection=0 \
  "$fixture_root/attacher.php" \
  "${php_arguments[@]}"
attacher_status=$?
set -e

if [[ "$attacher_status" -eq 0 ]]; then
  echo "The persisted internal-parent class passed the attachment check."
else
  printf 'The attacher could not instantiate the persisted internal-parent class (status %s).\n' \
    "$attacher_status" >&2
fi
exit "$attacher_status"
