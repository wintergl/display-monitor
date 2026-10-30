# Menu bar recovery in source build 61

This update addresses automatic collapse getting stuck after wake, a click
revealing again after a failed collapse, and otherwise complete menu bar
replicas differing by an offscreen status item.

## Recovery and clicks

Layout preparation keeps the existing 1, 2, and 4 second fast retries. If the
layout still cannot be proven safe, it waits 15, then 30, then 60 seconds between
checks, capped at 60 seconds. Each attempt requires fresh physical evidence.
Slow checks wait while the pointer is in the menu bar, mouse buttons are held,
a menu or popover is open, or interaction state cannot be read.

A click after a failed collapse starts a new safe collapse attempt. A click
during an active request keeps the existing user-intent behavior. Reveal,
disable, sleep, and termination cancel pending recovery. Native failures and
timeouts still have bounded retries; native safety lockouts remain in force.

## Replica differences

A replica may be accepted as a strict subset of another only when every shared
item has identical ownership, geometry, identifiers, and proxy semantics.
Every additional item requires independent evidence: one offscreen status item
owned by its live application and three hit tests showing the foreground menu
bar or a system button at the corresponding raw-graph geometry. Evidence is
bound to the current graph revision, expires after two seconds, and is
discarded if the foreground application changes during the read.

The complete superset is retained, including the offscreen owner. No app
allowlist, intersection, guessed ownership, or dropped item substitutes for
proof. Ambiguous graphs, unknown nodes, invalid boundaries, changed owners, and
stale evidence remain rejected. Native collapse still requires two fresh
complete proofs with identical target sets and all existing anchor and
protected-item checks.

## Validation scope

The publication checkout passed 695 tests, with one opt-in stress test skipped
and zero failures. Its public-source allowlist and sensitive-pattern audit
also passed. The public Release app bundle built successfully with ad hoc
signing, and bundle structure and signature validation passed.

Regression tests cover wake notifications followed by layout stabilization,
retry clicks after layout failure or native timeout, cancellation, interaction
gating, and accepted and rejected replica evidence. These tests use synthetic
fixtures and fake native operations.

The signed build 61 was also checked with a read-only probe of the original
replica difference and a normal reveal/collapse desktop cycle. The exact
original replica difference was no longer present during that desktop cycle.
Real sleep/wake acceptance remains pending; synthetic notification tests are
not a claim that a physical sleep/wake cycle passed.

This commit updates source and the source bundle version to 0.1.1 (61). It
does not replace the existing release assets or claim notarization of a source
build; the public build script retains its portable ad hoc signing default.
