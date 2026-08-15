<?php

declare(strict_types=1);

$fixture = realpath($argv[1] ?? '');
if ($fixture === false) {
    fwrite(STDERR, "The persistence fixture does not exist.\n");
    exit(1);
}

require $fixture;
if (ahe_persistent_fixture() !== 'the cache remembers') {
    fwrite(STDERR, "The persistence fixture returned the wrong value.\n");
    exit(1);
}
if (!opcache_is_script_cached($fixture)) {
    fwrite(STDERR, "The creator did not cache the persistence fixture.\n");
    exit(1);
}
