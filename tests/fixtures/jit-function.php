<?php

declare(strict_types=1);

namespace Ahe\Jit;

final class RetainedResult
{
    public static function extremeIdentity(self ...$results): self
    {
        return $results[0] ?? new self();
    }
}

final class RetainedType
{
    public function accepts(self $innerType, bool $strictTypes): RetainedResult
    {
        throw new \RuntimeException($strictTypes ? 'value:7' : 'unexpected');
    }
}

final class RetainedUnion
{
    /** @param list<RetainedType> $types */
    public function __construct(private array $types)
    {
    }

    public function isAcceptedBy(
        RetainedType $acceptingType,
        bool $strictTypes,
    ): RetainedResult {
        return RetainedResult::extremeIdentity(...array_map(
            static fn (RetainedType $innerType): RetainedResult => $acceptingType->accepts(
                $innerType,
                $strictTypes,
            ),
            $this->types,
        ));
    }
}

function retainedWholeFunction(): string
{
    try {
        (new RetainedUnion([new RetainedType()]))->isAcceptedBy(
            new RetainedType(),
            true,
        );
    } catch (\RuntimeException $exception) {
        return $exception->getMessage();
    }

    throw new \LogicException('The retained callback did not throw.');
}
