<?php

declare(strict_types=1);

$jitCheck = ($argv[1] ?? null) === '--jit';
if ($jitCheck) {
    $jitStatus = opcache_get_status(false)['jit'] ?? null;
    if (!is_array($jitStatus)
        || ($jitStatus['enabled'] ?? false) !== true
        || ($jitStatus['on'] ?? false) !== true
        || ($jitStatus['buffer_size'] ?? 0) <= 0
    ) {
        fwrite(STDERR, "The creator did not start with JIT enabled.\n");
        exit(1);
    }
}

$file = __DIR__ . '/classes/Lookahead.php';
require $file;
new Ahe\Reducer\Lookahead(new ArrayIterator([]));
if (!opcache_is_script_cached($file)) {
    fwrite(STDERR, "The creator did not cache the internal-inheritance fixture.\n");
    exit(1);
}
