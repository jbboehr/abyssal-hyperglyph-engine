<?php

declare(strict_types=1);

function exerciseJitStubTable(int $value): int
{
    for ($i = 0; $i < 1024; $i++) {
        $value = (($value * 33) ^ $i) & 0x7fffffff;
    }
    return $value;
}

$jitCheck = ($argv[1] ?? null) === '--jit';
$jitBufferFreeBefore = null;
if ($jitCheck) {
    $jitStatus = opcache_get_status(false)['jit'] ?? null;
    if (!is_array($jitStatus)
        || ($jitStatus['enabled'] ?? false) !== true
        || ($jitStatus['on'] ?? false) !== true
        || ($jitStatus['buffer_size'] ?? 0) <= 0
    ) {
        fwrite(STDERR, "The attacher did not start with JIT enabled.\n");
        exit(1);
    }
    $jitBufferFreeBefore = $jitStatus['buffer_free'] ?? null;
}

$file = __DIR__ . '/classes/Lookahead.php';
if (!opcache_is_script_cached($file)) {
    fwrite(STDERR, "The attacher did not reuse the retained generation.\n");
    exit(1);
}

require $file;
new Ahe\Reducer\Lookahead(new ArrayIterator([]));

if ($jitCheck) {
    $jitResult = exerciseJitStubTable(1);
    $jitBufferFreeAfter = opcache_get_status(false)['jit']['buffer_free'] ?? null;
    if (!is_int($jitBufferFreeBefore)
        || !is_int($jitBufferFreeAfter)
        || $jitBufferFreeAfter >= $jitBufferFreeBefore
        || $jitResult !== 181657601
    ) {
        fwrite(STDERR, "The attacher did not emit JIT code through the retained stub table.\n");
        exit(1);
    }
}

echo "The persisted internal-inheritance class linked successfully.\n";
