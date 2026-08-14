#!/usr/bin/env bash

set -euo pipefail

extension_path=${1:-modules/abyssal_hyperglyph_engine.so}
php_binary=${TEST_PHP_EXECUTABLE:-php}
extension_name='Abyssal Hyperglyph Engine: Gate of the Adamantine Oath'

if [[ ! -f "$extension_path" ]]; then
  echo "Zend extension not found: $extension_path" >&2
  exit 1
fi

extension_path=$(realpath "$extension_path")

actual=$(
  "$php_binary" \
    -n \
    -d "zend_extension=$extension_path" \
    -r 'echo implode(PHP_EOL, get_loaded_extensions(true)), PHP_EOL;'
)

if ! grep -Fqx "$extension_name" <<<"$actual"; then
  echo "Zend extension did not appear in the loaded extension list" >&2
  exit 1
fi

printf 'Loaded %s\n' "$extension_name"
