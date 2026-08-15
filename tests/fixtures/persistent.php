<?php

declare(strict_types=1);

class AhePersistentFixtureParent
{
    public function message(): string
    {
        return 'the cache remembers';
    }
}

final class AhePersistentFixtureChild extends AhePersistentFixtureParent
{
}

function ahe_persistent_fixture(): string
{
    return (new AhePersistentFixtureChild())->message();
}
