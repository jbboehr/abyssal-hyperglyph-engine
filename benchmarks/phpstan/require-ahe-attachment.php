<?php

declare(strict_types=1);

$maps = file_get_contents('/proc/self/maps');
$status = opcache_get_status(false);
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
