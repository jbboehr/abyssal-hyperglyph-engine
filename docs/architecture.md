# Architecture

## Objective

Retain OPcache's shared-memory cache between independent PHP CLI invocations while preserving ordinary CLI execution semantics.

The initial use case is PHPStan in controlled local and CI environments. The first Linux prototype therefore accepts an explicit ASLR-disabled launcher as a deployment constraint.

## Current milestone

The repository contains a PHP 8.4 patch that exports a version-two shared-memory provider registration function. The lock-descriptor callback was introduced with version two so an extension and OPcache built for different callback layouts cannot register with one another. AHE observes OPcache's `ZEND_EXTMSG_NEW_EXTENSION` event and registers while OPcache's dynamic-library handle is still available. OPcache allocates shared memory later from its post-startup callback, so registration is complete before allocator startup.

When `AHE_BROKER_SOCKET` is set, the provider connects to `ahe-broker`, authenticates the peer and socket ownership, receives cache and lock `memfd` descriptors through `SCM_RIGHTS`, and maps the cache. The creator publishes its mapping base and shared allocator-globals offset only after OPcache finishes startup. A later process maps the same descriptor and address with `MAP_FIXED_NOREPLACE`, restores the allocator-globals pointer, and enters OPcache's existing `SUCCESSFULLY_REATTACHED` path.

The integration checks deliberately abort one creator, build a replacement generation, reject size and layout mismatches, bound contention against the serial broker, recover an owned stale socket, verify prompt signal-driven shutdown, and prove that a final independent PHP invocation sees and hits the first successful process's cached script.

The `ahe-php` launcher sets Linux's `ADDR_NO_RANDOMIZE` personality flag before executing PHP. AHE verifies the launcher contract during Zend startup. This is necessary because changing the personality after the PHP executable and extensions have been mapped cannot stabilize their addresses.

## Proposed flow

1. AHE loads as a Zend extension before OPcache and registers an external shared-memory provider through a small OPcache API patch.
2. The provider connects to a per-user broker over a Unix domain socket.
3. The broker creates the cache and synchronization file descriptors for the first process.
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

The version-two scaffold implements registration, allocation, detachment, publication, shutdown, and both lock callbacks and the native lock descriptor required by OPcache's request/restart accounting. A successful fresh startup reports the shared allocator-globals address to the provider; a successful reattachment must return the corresponding address in its process-local mapping before OPcache reads the restored cache. Explicit generation retirement belongs with the broker protocol and is not implemented yet.

The existing shared-memory startup code already distinguishes a new allocation from `SUCCESSFULLY_REATTACHED`. The new provider should reuse that path rather than duplicating accelerator initialization.

## Safety invariants

- Cache keys include the effective user, SAPI, finalized Zend system ID, a sorted digest of every active `opcache.*` directive, the engine entry-point address, allocation size, and an explicit namespace.
- Every participant must use the same memory and lock objects.
- Once OPcache accepts a provider, the provider's shared object must remain loaded until OPcache has finished its post-shutdown callbacks.
- Raw pointers require the same mapping base in every process.
- The saved engine entry-point address must match the attaching process.
- Participants must be launched with ASLR disabled before PHP is mapped; an address mismatch rejects the cache.
- Fixed mappings must never replace an occupied range; use `MAP_FIXED_NOREPLACE` where available.
- Clients may attach only after the creator publishes a ready state.
- A creator crash during initialization must cause the incomplete generation to be discarded.
- Broker and client credentials must match, and the socket and its parent directory must remain private to that user.
- Failure to attach must degrade safely, initially to ordinary OPcache or its file cache.

## Initial implementation boundaries

The functional prototype targets non-ZTS Linux and PHP 8.4 with JIT and preloading disabled. It is optimized for PHPStan rather than arbitrary untrusted CLI workloads. The current broker holds one ready generation, serves one connected client at a time, and relies on an explicitly supplied private socket path. A queued client waits for at most one second and then uses local OPcache; the broker does not yet provide concurrent shared-cache access. Sequential reuse, creator abort, configuration mismatch, contention fallback, safe stale-socket restart, and signal shutdown are covered. Generation retirement, complete loaded-module fingerprinting, deliberate address collisions, and scripts that inherit from internal classes still require dedicated coverage.

## Patch maintenance

Keep a small patch series under `patches/php/<minor>/` and apply it to pristine PHP release sources in the package build. Do not vendor complete OPcache source trees unless the integration grows too invasive to maintain as reviewable patches. Porting to another PHP minor should include an apply/build test and the two-process reattachment test for that minor.
