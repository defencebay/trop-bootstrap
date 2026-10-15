<!-- BEGIN TROP SHARED RULES -->
<!-- source=http://gmktec.local:3000/defencebay/trop.git revision=a95c0fe0575bb8f2031cc923bb83c2ed581e2b31 sha256=415929c188de1fef46faf44f05db30583a11db4d5778eef7e15592945518cc91 -->
# TROP Shared Review Rules

Apply these rules to changed code, configuration and documentation and the affected
callers. Apply repository rules below this baseline and relevant component rules.
Treat local rules as specializations or stronger requirements. Accept a weaker
local rule only when an exception names the shared rule ID, scope, rationale and
explicit human approval reference. Flag an unexplained conflict; do not infer
precedence from document order. Apply rules only where their stated condition exists.

## 00. Review Contract

- **TROP-REVIEW-001:** Write concise, actionable inline review comments. Open with a short, specific title naming the issue. In a brief body, explain the triggering condition, the demonstrated impact or violated standard, and the smallest useful correction. Anchor the comment to the relevant lines and keep one issue per thread. Use direct, factual language; set severity according to demonstrated impact and scope. Report behavioral defects and violations of adopted architecture, design and readability standards without inventing runtime consequences. Do not add custom category labels or require fixed section headings.
- **TROP-REVIEW-002:** Cite the applicable rule ID and exact changed location. Explain the evidence and smallest useful correction. Read affected callers, contracts and tests before asserting a violation. Do not invent requirements, consumers, command results or verification evidence.
- **TROP-REVIEW-003:** Report each underlying issue once. Prefer the most specific applicable rule ID, including existing local IDs. Do not manufacture findings to complete a checklist. Do not report a pre-existing issue unless the change introduces a new failure path or demonstrably worsens it.
- **TROP-REVIEW-004:** Use formatters, linters and generated checks for mechanical style. Report weakened checks and substantive design/readability violations that automation does not establish. Do not repeat a diagnostic already present on the same head without additional actionable information.
- **TROP-REVIEW-005:** Reopen resolved review comments and threads when the reported issue remains unaddressed in the current code. Verify the actual fix and supporting evidence before accepting resolution. Do not silently skip a reported issue solely because its comment or thread was marked resolved.

## 01. Architecture & Boundaries

- **TROP-ARCH-006:** Enforce SOLID and DRY in every repository as mandatory engineering standards. Report concrete violations without requiring a repository-local declaration. Apply the principles to functions, modules, interfaces and classes as appropriate to the language.

### Single Responsibility (SRP)

- **TROP-DESIGN-001:** Flag classes, functions or modules that implement unrelated responsibilities with separate reasons to change. Flag business policy mixed inline with credential resolution, network I/O, persistence or external-type mapping. Separate those responsibilities into focused collaborators; keep orchestration delegating the steps instead of implementing them all inline.

### Open/Closed (OCP)

- **TROP-ARCH-003:** Flag extensions that spread type- or mode-specific conditionals across shared policy, duplicate dispatch decisions, or require modifying unrelated existing handlers to add a supported variant. Isolate variant-specific behavior behind focused implementations or extension points and keep shared orchestration stable.

### Liskov Substitution (LSP)

- **TROP-DESIGN-003:** Flag implementations that reject inputs accepted by the base contract, weaken promised results or invariants, throw unsupported-operation errors for required operations, or silently ignore required behavior. Require every implementation to remain substitutable for its declared contract; identify the caller expectation it violates.

### Interface Segregation (ISP)

- **TROP-ARCH-002:** Flag interfaces that force clients or implementations to depend on unrelated operations they do not need. Split them into small, focused capabilities. Flag dummy implementations, empty methods or unsupported-operation errors introduced solely to satisfy unused interface members.

### Dependency Inversion (DIP)

- **TROP-ARCH-001:** Flag business and use-case policy that directly constructs or depends on concrete persistence, transport or vendor integration implementations. Express the required capabilities through small consumer-owned interfaces or callable contracts and supply concrete implementations at the composition boundary. Keep vendor SDK, transport and database types out of policy contracts; translate them at integration boundaries.

### Don't Repeat Yourself (DRY)

- **TROP-ARCH-005:** Flag duplicated business rules, validation, authorization decisions, protocol mappings or configuration knowledge that must be edited together to preserve the same invariant. Establish one maintained source for that knowledge and reuse it or generate its representations. Distinguish duplicated knowledge from similar syntax that represents different concepts; extract around the shared rule rather than superficial resemblance.

### License constraints

- **TROP-ARCH-004:** Flag any copyleft-licensed dependency or included material, including direct, transitive, optional and build dependencies, vendored or copied code, and bundled artifacts. Identify the component, declared license, version or source revision, and dependency or inclusion path. Verify the license from metadata or license notices; do not infer it from the component name.

## 02. Design & Complexity

- **TROP-DESIGN-002:** Flag abstractions, wrappers or configuration switches that add indirection without serving a current requirement, a real boundary or meaningful test isolation. Preserve useful interfaces with one implementation; implementation count alone does not prove overengineering.
- **TROP-DESIGN-004:** Flag exposed mutable state, public implementation details and ambiguous names that contradict adopted encapsulation or naming standards. Name the leaked invariant or the competing meanings. Do not request speculative renames based only on preference.
- **TROP-DESIGN-005:** Flag nested branching or mode flags that obscure distinct operations and duplicate their decisions across callers. Propose the simplest structure that makes the existing behavior explicit; do not demand a design pattern by default.

## 03. Contracts & Compatibility

- **TROP-CONTRACT-001:** Trace changed API, event, file and protocol contracts through supported producers and consumers. Flag incompatible changes without an explicit compatibility decision and migration path. Include semantics, defaults, units and error behavior, not just schema shape.
- **TROP-CONTRACT-002:** Flag parsers that silently turn malformed, truncated, oversized or unsupported input into valid state. Validate limits and required fields at the trust boundary. Use the established structured codec instead of delimiter or regex parsing for structured formats.
- **TROP-CONTRACT-003:** Flag hand-edited generated artifacts or source changes without the corresponding required regeneration. Verify generated output against its actual source and supported toolchain.

## 04. Data & State

- **TROP-DATA-001:** Trace related writes, reads and externally visible effects as one operation. Flag partial commits, inconsistent snapshots and races that break a declared invariant. Identify the failing sequence and transaction or ownership boundary.
- **TROP-DATA-002:** Flag schema or data migrations that lose supported existing data, break retained readers/writers or make the stated rollback impossible. Distinguish fresh-install success from same-storage upgrade compatibility.
- **TROP-DATA-003:** Flag stale updates overwriting newer state, shared mutable payload aliasing and caches that survive changes to the identity, authorization or data they represent. Identify the invalidation or version condition that is missing.

## 05. Concurrency & Lifecycle

- **TROP-LIFE-001:** Trace ownership and termination of background work, subscriptions, timers, connections and streams. Flag work that outlives its owner without an explicit lifecycle, or blocks shutdown because cancellation does not reach it.
- **TROP-LIFE-002:** Trace concurrent access, replacement and cleanup. Flag unsynchronized shared state, use-after-close and stale callbacks mutating a replacement session. State the concrete interleaving.
- **TROP-LIFE-003:** Trace ordering, deduplication, catch-up and live delivery where the contract requires them. Flag gaps or duplicates at their handoff. Do not equate transport write success with application receipt or durable acceptance.

## 06. Errors & Resilience

- **TROP-ERR-001:** Flag discarded failures, false-success responses and fallback values that hide an unsuccessful required operation. Preserve the original cause and classify errors by stable types or codes instead of message fragments.
- **TROP-ERR-002:** Flag retries without a finite budget or termination condition, retries of non-idempotent effects without duplicate protection, and retry loops that disregard cancellation or amplify overload.
- **TROP-ERR-003:** Flag external operations that can wait indefinitely without an explicit supported reason. Trace timeout and cancellation propagation through the operation, including blocking I/O and cleanup.
- **TROP-ERR-004:** Flag technical error details exposed across a public boundary. Preserve useful internal diagnostics while returning the contract's stable, appropriate error representation.

## 07. Security & Privacy

- **TROP-SEC-001:** Derive identity from the authenticated context. Flag caller-controlled identifiers used as authentication and resource access without authorization for the authenticated subject and scope.
- **TROP-SEC-002:** Flag committed credentials, private keys, tokens and credential-bearing connection strings. Flag secrets or unnecessary personal/location data exposed through logs, errors, telemetry, URLs or artifacts. Check nested payloads, not just field names.
- **TROP-SEC-003:** Flag untrusted data reaching commands, queries, paths, redirects or rendered content without the required boundary protection. Identify the attacker-controlled value and reachable sink; do not claim exploitability from a string match alone.
- **TROP-SEC-004:** Flag disabled certificate/hostname verification, insecure production defaults and authentication bypasses. Require explicit separation of development-only allowances from supported deployment behavior.

## 08. Performance & Capacity

- **TROP-PERF-001:** Flag unbounded collections, queues, replay windows, payloads or background work reachable from sustained input. Identify the growth source, lifetime and missing capacity or backpressure policy.
- **TROP-PERF-002:** Flag repeated remote calls or whole-dataset loading where supported source-side batching, filtering or pagination avoids a demonstrated unnecessary cost while preserving semantics. Do not assume every datasource supports those operations.
- **TROP-PERF-003:** Flag resource/client creation on a hot path when the client is designed for reuse and repeated construction has a concrete cost or lifecycle problem. Respect thread-safety and per-request credential boundaries.

## 09. Observability

- **TROP-OBS-001:** Flag required failures and overload rejections that are invisible to callers or operators. Include the missing signal and diagnostic context. Metrics alone do not justify silently losing data promised by the contract.
- **TROP-OBS-002:** Flag duplicate exception logging and high-volume per-item or retry logging that obscures operational failures. Use the repository's structured context and log-level conventions; retain the cause where the failure is handled.
- **TROP-OBS-003:** Flag misleading success metrics, incorrect units and missing correlation across asynchronous boundaries when those signals underpin supported operations. Identify the operational question the emitted signal answers incorrectly.

## 10. Test Quality

- **TROP-TEST-001:** Inspect regression coverage for changed behavior and invariants. Flag tests with no meaningful assertion, self-referential expected values or assertions that still pass when the behavior is broken. State the missing regression scenario.
- **TROP-TEST-002:** Flag tests relying on execution order, unscoped shared state or arbitrary delays to establish a state transition. Require observable wait conditions with bounded deadlines. Preserve intentional timing tests and delays required by the protocol under test.
- **TROP-TEST-003:** Match verification to the changed risk: deterministic tests for rules, focused integration tests for boundaries and runtime checks for lifecycle/interoperability claims. Flag claims of verification that the recorded command or fixture cannot establish. Do not demand unrelated suites for guidance-only changes.
- **TROP-TEST-004:** Flag changes that weaken assertions, skip relevant cases or alter the oracle to accommodate a defect without an approved behavior change. Do not replace required runtime validation of untrusted input with confidence in tests.

## 11. Build, Dependencies & Delivery

- **TROP-BUILD-001:** Flag dependency or toolchain changes incompatible with supported targets, inconsistent with the lockfile, or bypassing established update policy. Preserve justified compatibility pins; do not assume every explicit version is unnecessary.
- **TROP-BUILD-002:** Flag untrusted PR-controlled code running with publication credentials, required checks skipped for the final head, and artifacts published without binding to their verified source revision.
- **TROP-BUILD-003:** Flag deployment/configuration changes that break supported installation or upgrade paths, omit required runtime configuration or contradict the stated rollback. Do not treat a plan, draft PR or local verification as permission to deploy or switch production authority.
<!-- END TROP SHARED RULES -->

# trop-bootstrap Review Rules

Apply these local specializations together with the TROP baseline. Follow the
repository's adopted guidance and the source contracts for the changed component.

## 03. Contracts & Compatibility

- **BOOTSTRAP-CONTRACT-001:** Preserve the fresh-install, upgrade and fetch-only behavior documented in README.md. Flag fetch-only execution that starts installation or mutates the supported runtime.

## 04. Data & State

- **BOOTSTRAP-DATA-001:** Scope changes to host files, trust stores and installation state to the selected options and TROP-owned entries. Flag replacement of unrelated host entries, certificates or existing persisted installation data.

## 07. Security & Privacy

- **BOOTSTRAP-SEC-001:** Preserve release/signature verification before execution and the hidden token input. Flag credential-bearing shell tracing, persisted registry credentials outside their owned temporary directory or verification bypasses.

## 11. Build, Dependencies & Delivery

- **BOOTSTRAP-BUILD-001:** Keep selected release assets, retained signatures and Zarf/package versions coherent. Flag an upgrade that combines configuration from one release with executable artifacts from another.
