<?php

declare(strict_types=1);

$expectedBlacklist = getenv('AHE_BENCHMARK_EXPECT_BLACKLIST') === '1';
$expectedBlacklistFile = (string) getenv('AHE_BENCHMARK_BLACKLIST_FILE');
$actualBlacklistFile = (string) ini_get('opcache.blacklist_filename');
if (($expectedBlacklist && $actualBlacklistFile !== $expectedBlacklistFile)
    || (!$expectedBlacklist && $actualBlacklistFile !== '')
) {
    fwrite(STDERR, "A PHPStan process started with the wrong OPcache blacklist.\n");
    exit(86);
}

$expectedFileCache = getenv('AHE_BENCHMARK_EXPECT_FILE_CACHE') === '1';
$fileCacheOnly = filter_var(ini_get('opcache.file_cache_only'), FILTER_VALIDATE_BOOL);
if ($fileCacheOnly !== $expectedFileCache) {
    fwrite(STDERR, "A PHPStan process started with the wrong OPcache file-cache mode.\n");
    exit(86);
}

if ($expectedFileCache) {
    $fileCacheDirectory = (string) getenv('AHE_BENCHMARK_FILE_CACHE_DIRECTORY');
    $probeFile = (string) getenv('AHE_BENCHMARK_FILE_CACHE_PROBE');
    if ($fileCacheDirectory === '' || ini_get('opcache.file_cache') !== $fileCacheDirectory) {
        fwrite(STDERR, "A PHPStan process started with the wrong file-cache directory.\n");
        exit(86);
    }
    if ($probeFile === '' || (require $probeFile) !== 111) {
        fwrite(STDERR, "A PHPStan process did not load the primed file-cache probe.\n");
        exit(86);
    }

    $markerDirectory = (string) getenv('AHE_BENCHMARK_FILE_CACHE_MARKER_DIRECTORY');
    if (!is_dir($markerDirectory)) {
        fwrite(STDERR, "The benchmark file-cache marker directory does not exist.\n");
        exit(86);
    }
    $processType = ($_SERVER['argv'][1] ?? null) === 'worker' ? 'worker' : 'parent';
    if (file_put_contents(
        $markerDirectory . '/' . $processType . '-' . getmypid(),
        "file-cache-hit\n",
    ) === false) {
        fwrite(STDERR, "A PHPStan process could not record its file-cache hit.\n");
        exit(86);
    }
}

$expectedJitMode = (string) getenv('AHE_BENCHMARK_EXPECT_JIT_MODE');
$status = opcache_get_status(false);
$jit = is_array($status) ? ($status['jit'] ?? null) : null;
$jitEnabled = is_array($jit)
    && ($jit['enabled'] ?? false) === true
    && ($jit['on'] ?? false) === true;
$actualJitMode = $jitEnabled ? strtolower((string) ini_get('opcache.jit')) : 'off';
if ($actualJitMode !== $expectedJitMode) {
    fwrite(
        STDERR,
        sprintf(
            "A PHPStan process started with JIT mode %s instead of %s.\n",
            $actualJitMode,
            $expectedJitMode,
        ),
    );
    exit(86);
}

if (getenv('AHE_BENCHMARK_EXPECT_ATTACHMENT') !== '1') {
    return;
}

$maps = file_get_contents('/proc/self/maps');
if ($maps === false || !str_contains($maps, '/memfd:ahe-opcache') || $status === false) {
    fwrite(STDERR, "A PHPStan process fell back to process-local OPcache.\n");
    exit(86);
}

$markerDirectory = (string) getenv('AHE_BENCHMARK_ATTACHMENT_DIRECTORY');
if (!is_dir($markerDirectory)) {
    fwrite(STDERR, "The benchmark attachment-marker directory does not exist.\n");
    exit(86);
}

$processType = ($_SERVER['argv'][1] ?? null) === 'worker' ? 'worker' : 'parent';
if (file_put_contents(
    $markerDirectory . '/' . $processType . '-' . getmypid(),
    "attached\n",
) === false) {
    fwrite(STDERR, "A PHPStan process could not record its AHE attachment.\n");
    exit(86);
}
