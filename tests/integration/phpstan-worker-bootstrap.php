<?php

declare(strict_types=1);

$fixture = realpath((string) getenv('AHE_PHPSTAN_PERSISTED_FIXTURE'));
$markerDirectory = (string) getenv('AHE_PHPSTAN_MARKER_DIRECTORY');
$personality = hexdec(trim((string) file_get_contents('/proc/self/personality')));
$status = opcache_get_status(true);
$jit = is_array($status) ? ($status['jit'] ?? null) : null;
$cachedScripts = is_array($status) ? ($status['scripts'] ?? null) : null;

if ($fixture === false || !opcache_is_script_cached($fixture)) {
    fwrite(STDERR, "A PHPStan process did not attach to the retained OPcache generation.\n");
    exit(86);
}
require_once $fixture;
if (ahe_persistent_fixture() !== 'the cache remembers') {
    fwrite(STDERR, "A PHPStan process could not link a persisted child class.\n");
    exit(86);
}
if (($personality & 0x40000) === 0 || getenv('AHE_EXPECT_NO_ASLR') !== '1') {
    fwrite(STDERR, "A PHPStan process did not inherit the AHE launcher contract.\n");
    exit(86);
}
if (!is_array($jit)
    || ($jit['enabled'] ?? false) !== true
    || ($jit['on'] ?? false) !== true
    || ($jit['kind'] ?? null) !== 0
    || ($jit['opt_level'] ?? null) !== 5
) {
    fwrite(STDERR, "A PHPStan process did not inherit whole-function JIT.\n");
    exit(86);
}
if (!is_array($cachedScripts)
    || !array_any(
        array_keys($cachedScripts),
        static fn (string $path): bool => str_starts_with($path, 'phar://'),
    )
) {
    fwrite(STDERR, "A PHPStan process did not find cached PHPStan PHAR scripts.\n");
    exit(86);
}
if (!is_dir($markerDirectory)) {
    fwrite(STDERR, "The PHPStan attachment marker directory does not exist.\n");
    exit(86);
}
$processType = ($_SERVER['argv'][1] ?? null) === 'worker' ? 'worker' : 'parent';
if (file_put_contents(
    $markerDirectory . '/' . $processType . '-' . getmypid(),
    "attached\n",
) === false) {
    fwrite(STDERR, "A PHPStan process could not record its attachment.\n");
    exit(86);
}
