<?php

declare(strict_types=1);

$status = opcache_get_status(false);
$jit = is_array($status) ? ($status['jit'] ?? null) : null;
$maps = file_get_contents('/proc/self/maps');
if (!is_array($jit)
    || ($jit['enabled'] ?? false) !== true
    || ($jit['on'] ?? false) !== true
    || ($jit['kind'] ?? null) !== 0
    || ($jit['opt_level'] ?? null) !== 5
    || $maps === false
    || !str_contains($maps, '/memfd:ahe-opcache')
) {
    fwrite(STDERR, "The attacher did not start in attached whole-function JIT mode.\n");
    exit(1);
}

$fixture = getenv('AHE_JIT_FUNCTION_FIXTURE');
$file = is_string($fixture) && $fixture !== ''
    ? $fixture
    : __DIR__ . '/functions.php';
$startReadyFile = getenv('AHE_JIT_FUNCTION_START_READY_FILE');
$startReleaseFile = getenv('AHE_JIT_FUNCTION_START_RELEASE_FILE');
$concurrentStart = is_string($startReadyFile) && $startReadyFile !== ''
    && is_string($startReleaseFile) && $startReleaseFile !== '';
if (!opcache_is_script_cached($file)) {
    fwrite(STDERR, "The attacher did not find the creator's cached fixture.\n");
    exit(1);
}
if ($concurrentStart) {
    if (file_put_contents($startReadyFile, "ready\n") === false) {
        fwrite(STDERR, "The attacher could not publish its start-ready marker.\n");
        exit(1);
    }
    while (!is_file($startReleaseFile)) {
        usleep(10_000);
    }
}

$bufferFreeBefore = opcache_get_status(false)['jit']['buffer_free'] ?? null;
require $file;
$result = Ahe\Jit\retainedWholeFunction();
$bufferFreeAfter = opcache_get_status(false)['jit']['buffer_free'] ?? null;

if ($result !== 'value:7') {
    fwrite(STDERR, "The attacher got an unexpected result from retained JIT code.\n");
    exit(1);
}
if (!is_int($bufferFreeBefore)
    || !is_int($bufferFreeAfter)
    || $bufferFreeAfter !== $bufferFreeBefore
) {
    fwrite(STDERR, "The attacher emitted code instead of reusing the retained function.\n");
    exit(1);
}

echo "The attacher executed the creator's retained whole-function JIT code.\n";
