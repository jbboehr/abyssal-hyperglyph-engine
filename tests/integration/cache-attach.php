<?php

declare(strict_types=1);

$fixture = realpath($argv[1] ?? '');
if ($fixture === false) {
    fwrite(STDERR, "The persistence fixture does not exist.\n");
    exit(1);
}
if (!opcache_is_script_cached($fixture)) {
    fwrite(STDERR, "The fixture was not present before the second invocation included it.\n");
    exit(1);
}

$before = opcache_get_status(true);
$hitsBefore = $before['scripts'][$fixture]['hits'] ?? null;
if (!is_int($hitsBefore)) {
    fwrite(STDERR, "The restored cache did not contain fixture statistics.\n");
    exit(1);
}

require $fixture;
if (ahe_persistent_fixture() !== 'the cache remembers') {
    fwrite(STDERR, "The restored fixture returned the wrong value.\n");
    exit(1);
}

$after = opcache_get_status(true);
$hitsAfter = $after['scripts'][$fixture]['hits'] ?? null;
if (!is_int($hitsAfter) || $hitsAfter <= $hitsBefore) {
    fwrite(STDERR, "The restored cache hit counter did not advance.\n");
    exit(1);
}
