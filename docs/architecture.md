# Architecture

## Objective

Retain OPcache's shared-memory cache between independent PHP CLI invocations while preserving ordinary CLI execution semantics.

The initial use case is PHPStan in controlled local and CI environments. The first Linux prototype therefore accepts an explicit ASLR-disabled launcher as a deployment constraint.

## Current milestone

The repository contains a PHP 8.4 patch that exports a version-two shared-memory provider registration function. The lock-descriptor callback was introduced with version two so an extension and OPcache built for different callback layouts cannot register with one another. AHE observes OPcache's `ZEND_EXTMSG_NEW_EXTENSION` event and registers while OPcache's dynamic-library handle is still available. OPcache allocates shared memory later from its post-startup callback, so registration is complete before allocator startup.

When `AHE_BROKER_SOCKET` is set, the provider connects to `ahe-broker`, authenticates the peer and socket ownership, receives cache and lock `memfd` descriptors through `SCM_RIGHTS`, and maps the cache. The creator publishes its mapping base and shared allocator-globals offset only after OPcache finishes startup. A later process maps the same descriptor and address with `MAP_FIXED_NOREPLACE`, restores the allocator-globals pointer, and enters OPcache's existing `SUCCESSFULLY_REATTACHED` path.

The integration checks deliberately abort one creator, build a replacement generation, reject size and layout mismatches, recover an owned stale socket, verify prompt signal-driven shutdown, and prove that concurrent PHP processes can attach, race to populate one script under OPcache's write lock, and leave it available to a final independent invocation. A PHPStan 2.2 smoke test additionally forces its parallel scheduler to spawn workers and verifies from an autoload hook that the parent and every worker attached to the retained generation.

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
- Once a generation is ready, the broker may serve clients concurrently; OPcache serializes shared-memory mutations through the common lock descriptor.
- Every participant must start with the same loaded extension set and inherited `opcache.*` configuration.
- `opcache.force_restart_timeout` must be zero: stock OPcache's forced-restart path terminates processes that still hold its request lock, but AHE's independent CLI participants are not replaceable FPM workers.
- Broker and client credentials must match, and the socket and its parent directory must remain private to that user.
- Failure to attach must degrade safely, initially to ordinary OPcache or its file cache.

## Initial implementation boundaries

The functional prototype targets non-ZTS Linux and PHP 8.4 with preloading disabled. JIT remains disabled by default. Tracing JIT and the whole-function, compile-on-script-load preset are supported as opt-in modes with dedicated reattachment coverage. Whole-function JIT remains process-local in the current benchmark matrix until an additional retained mode and a complete seven-row counterbalance are added. The prototype is optimized for PHPStan rather than arbitrary untrusted CLI workloads. The current broker holds one ready generation, multiplexes concurrent clients, and relies on an explicitly supplied private socket path. A second client that arrives while the first process is still constructing a cold generation is declined rather than queued; concurrent sharing begins only after the creator publishes `READY`.

PHPStan's spawned workers inherit the broker environment, loaded ini, and ASLR-disabled process personality, so they can attach while the parent remains active. Parent-only `-d` values are not inherited. PHPStan 2.2 PHARs also inject their bundled Turbo extension into worker commands only; set `PHPSTAN_TURBO=0` until AHE fingerprints loaded modules and supports separate compatible generations. A future PHPStan-specific launcher should instead discover the bundled Turbo binary before starting PHP and load it through an inherited ini fragment, giving the parent and every worker the same module and address layout; loading it only in the parent with `-d extension=...` would not satisfy that contract.

Sequential reuse, creator abort, configuration mismatch, concurrent attachment and population, internal-parent class linking, retained tracing and whole-function JIT, PHPStan worker attachment, safe stale-socket restart, and signal shutdown are covered. Generation retirement, complete loaded-module fingerprinting, and deliberate address collisions still require dedicated coverage.

The first PHPUnit 12.5.33 runs exposed unsafe persisted class-linking metadata. The failure reduced to one cached user class extending the internal `IteratorIterator` class: its creator succeeded, while an attacher could jump into the creator's `class_IteratorIterator_methods` data table. Disabling OPcache's inheritance-cache callbacks alone was insufficient because compile-time early binding had already linked the class against process-local internal metadata.

The packaged PHP build now enables PHP core's existing `ZEND_OPCACHE_SHM_REATTACHMENT` path on Linux, under the launcher's stable-address contract. This disqualifies internal-parent classes from the shared inheritance cache and installs hooked-property iterator handlers during request-local linking. The patched OPcache also compiles with `ZEND_COMPILE_IGNORE_INTERNAL_CLASSES`, preventing those classes from being early-bound against the creator's internal class entries. [`scripts/reproduce-class-linking.sh`](../scripts/reproduce-class-linking.sh) and its Nix check cover the reduced fault, while the pinned PHPUnit benchmark verifies independently spawned PHPStan workers against the full workload.

## Patch maintenance

Keep a small patch series under `patches/php/<minor>/` and apply it to pristine PHP release sources in the package build. Do not vendor complete OPcache source trees unless the integration grows too invasive to maintain as reviewable patches. Porting to another PHP minor should include an apply/build test and the two-process reattachment test for that minor.
