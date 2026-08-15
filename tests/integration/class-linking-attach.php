<?php

declare(strict_types=1);

$file = __DIR__ . '/classes/Lookahead.php';
if (!opcache_is_script_cached($file)) {
    fwrite(STDERR, "The attacher did not reuse the retained generation.\n");
    exit(1);
}

require $file;
new Ahe\Reducer\Lookahead(new ArrayIterator([]));
echo "The persisted internal-inheritance class linked successfully.\n";
