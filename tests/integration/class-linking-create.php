<?php

declare(strict_types=1);

$file = __DIR__ . '/classes/Lookahead.php';
require $file;
new Ahe\Reducer\Lookahead(new ArrayIterator([]));
if (!opcache_is_script_cached($file)) {
    fwrite(STDERR, "The creator did not cache the internal-inheritance fixture.\n");
    exit(1);
}
