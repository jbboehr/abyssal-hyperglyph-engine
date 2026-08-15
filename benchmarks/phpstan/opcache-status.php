<?php

declare(strict_types=1);

$projectRoot = realpath($argv[1] ?? '');
if ($projectRoot === false) {
    fwrite(STDERR, "The benchmark project directory does not exist.\n");
    exit(1);
}

$status = opcache_get_status(true);
if (!is_array($status)) {
    fwrite(STDERR, "OPcache status is unavailable.\n");
    exit(1);
}

$scripts = $status['scripts'] ?? [];
$scriptPaths = array_keys(is_array($scripts) ? $scripts : []);
$phpstanPharScripts = array_filter(
    $scriptPaths,
    static fn (string $path): bool => str_starts_with($path, 'phar://')
        && str_contains($path, 'phpstan.phar/'),
);
$projectScripts = array_filter(
    $scriptPaths,
    static fn (string $path): bool => str_starts_with($path, $projectRoot . DIRECTORY_SEPARATOR),
);
$jit = $status['jit'] ?? null;
$jitEnabled = is_array($jit)
    && ($jit['enabled'] ?? false) === true
    && ($jit['on'] ?? false) === true;
$actualJitMode = $jitEnabled ? strtolower((string) ini_get('opcache.jit')) : 'off';
$expectedJitMode = (string) getenv('AHE_BENCHMARK_EXPECT_JIT_MODE');
$jitStartupBufferFreeValue = (string) getenv('AHE_BENCHMARK_JIT_STARTUP_BUFFER_FREE');
$jitStartupBufferFree = filter_var(
    $jitStartupBufferFreeValue,
    FILTER_VALIDATE_INT,
    ['options' => ['min_range' => 1]],
);
$jitStartupBufferFree = is_int($jitStartupBufferFree) ? $jitStartupBufferFree : null;

$report = [
    'cache_full' => $status['cache_full'] ?? null,
    'restart_pending' => $status['restart_pending'] ?? null,
    'restart_in_progress' => $status['restart_in_progress'] ?? null,
    'num_cached_scripts' => $status['opcache_statistics']['num_cached_scripts'] ?? null,
    'hits' => $status['opcache_statistics']['hits'] ?? null,
    'misses' => $status['opcache_statistics']['misses'] ?? null,
    'used_memory' => $status['memory_usage']['used_memory'] ?? null,
    'free_memory' => $status['memory_usage']['free_memory'] ?? null,
    'phpstan_phar_scripts' => count($phpstanPharScripts),
    'project_scripts' => count($projectScripts),
    'jit_enabled' => $jitEnabled,
    'jit_mode' => $actualJitMode,
    'jit_buffer_size' => is_array($jit) ? ($jit['buffer_size'] ?? null) : null,
    'jit_buffer_free' => is_array($jit) ? ($jit['buffer_free'] ?? null) : null,
    'jit_startup_buffer_free' => $jitStartupBufferFree,
];

echo json_encode($report, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";

if ($report['phpstan_phar_scripts'] === 0) {
    fwrite(STDERR, "The retained generation contains no PHPStan PHAR scripts.\n");
    exit(1);
}
if ($report['project_scripts'] === 0) {
    fwrite(STDERR, "The retained generation contains no PHPUnit project scripts.\n");
    exit(1);
}
if ($actualJitMode !== $expectedJitMode) {
    fwrite(STDERR, "The retained generation has the wrong JIT mode.\n");
    exit(1);
}
if ($expectedJitMode !== 'off'
    && (!is_int($report['jit_buffer_size'])
        || !is_int($report['jit_buffer_free'])
        || !is_int($report['jit_startup_buffer_free'])
        || $report['jit_buffer_size'] <= 0
        || $report['jit_startup_buffer_free'] >= $report['jit_buffer_size']
        || $report['jit_buffer_free'] >= $report['jit_startup_buffer_free'])
) {
    fwrite(STDERR, "The retained JIT generation emitted no workload code beyond startup stubs.\n");
    exit(1);
}
if ($report['cache_full'] !== false
    || $report['restart_pending'] !== false
    || $report['restart_in_progress'] !== false
) {
    fwrite(STDERR, "The retained generation is full or restarting.\n");
    exit(1);
}
