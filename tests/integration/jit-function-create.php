<?php

declare(strict_types=1);

$status = opcache_get_status(false);
$jit = is_array($status) ? ($status['jit'] ?? null) : null;
if (!is_array($jit)
    || ($jit['enabled'] ?? false) !== true
    || ($jit['on'] ?? false) !== true
    || ($jit['kind'] ?? null) !== 0
    || ($jit['opt_level'] ?? null) !== 5
) {
    fwrite(STDERR, "The creator did not start with whole-function JIT enabled.\n");
    exit(1);
}

$bufferFreeBefore = $jit['buffer_free'] ?? null;
$fixture = getenv('AHE_JIT_FUNCTION_FIXTURE');
$file = is_string($fixture) && $fixture !== ''
    ? $fixture
    : __DIR__ . '/functions.php';

require $file;

$result = Ahe\Jit\retainedWholeFunction();
$bufferFreeAfter = opcache_get_status(false)['jit']['buffer_free'] ?? null;
if ($result !== 'value:7') {
    fwrite(STDERR, "The creator got an unexpected result from the fixture.\n");
    exit(1);
}
if (!is_int($bufferFreeBefore)
    || !is_int($bufferFreeAfter)
    || $bufferFreeAfter >= $bufferFreeBefore
) {
    fwrite(STDERR, "The creator did not emit whole-function JIT code for the fixture.\n");
    exit(1);
}
if (!opcache_is_script_cached($file)) {
    fwrite(STDERR, "The creator did not cache the whole-function JIT fixture.\n");
    exit(1);
}

echo "The creator cached and executed the whole-function JIT fixture.\n";

$readyFile = getenv('AHE_JIT_FUNCTION_READY_FILE');
$releaseFile = getenv('AHE_JIT_FUNCTION_RELEASE_FILE');
if (is_string($readyFile) && $readyFile !== ''
    && is_string($releaseFile) && $releaseFile !== ''
) {
    if (file_put_contents($readyFile, "ready\n") === false) {
        fwrite(STDERR, "The creator could not publish its ready marker.\n");
        exit(1);
    }
    while (!is_file($releaseFile)) {
        usleep(10_000);
    }
}
