# Architecture

## Objective

Retain OPcache's shared-memory cache between independent PHP CLI invocations while preserving ordinary CLI execution semantics.

## Proposed flow

1. AHE loads as a Zend extension before OPcache and registers an external shared-memory provider through a small OPcache API patch.
2. The provider connects to a per-user broker over a Unix domain socket.
3. The first process creates the cache and synchronization file descriptors and starts the broker.
4. The broker retains those descriptors after the creating PHP process exits.
5. Later processes receive duplicate descriptors through `SCM_RIGHTS`, map the cache at its original virtual address, and return OPcache's existing `SUCCESSFULLY_REATTACHED` result.

The cache should use `memfd_create()` on Linux. A POSIX shared-memory descriptor can provide a portability path without exposing the cache through a permanent filesystem entry.

## Required OPcache seam

The initial PHP patch should expose the smallest practical interface:

- register or override a shared-memory handler before OPcache post-startup;
- provide a common inter-process lock descriptor instead of creating one private lock per PHP process;
- notify the provider when initial cache construction has completed;
- detach process-local mappings without destroying the broker-owned cache;
- invalidate or retire a cache generation explicitly.

The existing shared-memory startup code already distinguishes a new allocation from `SUCCESSFULLY_REATTACHED`. The new provider should reuse that path rather than duplicating accelerator initialization.

## Safety invariants

- Cache keys must include the effective user, SAPI, Zend system ID, relevant OPcache configuration, and an explicit cache namespace.
- Every participant must use the same memory and lock objects.
- Raw pointers require the same mapping base in every process.
- The saved engine entry-point address must match the attaching process.
- Fixed mappings must never replace an occupied range; use `MAP_FIXED_NOREPLACE` where available.
- Clients may attach only after the creator publishes a ready state.
- A creator crash during initialization must cause the incomplete generation to be discarded.
- Broker and client credentials must match.
- Failure to attach must degrade safely, initially to ordinary OPcache or its file cache.

## Initial implementation boundaries

The first functional prototype should target non-ZTS Linux and disable JIT and preloading. It should test sequential reuse, concurrent startup, client crashes, broker restarts, incompatible builds, address collisions, and scripts that inherit from internal classes before expanding the supported configuration.
