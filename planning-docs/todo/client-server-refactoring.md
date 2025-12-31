# Client/Server Architecture Refactoring Plan

## Implementation Status

**Status: COMPLETE** (as of 2026-01-29)

All phases have been implemented:

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 0: Test Audit | ✅ Complete | Added progress token injection tests, capability auto-inference tests |
| Client Phase 1: Progress Token Injection | ✅ Complete | Centralized in ProtocolLayer with `metaValues` parameter |
| Client Phase 2: Handler State Consolidation | ✅ Complete | Created `ClientHandlerRegistry` with `inferCapabilities()` |
| Client Phase 3: Capability Helpers | ✅ Complete | Created `ClientCapabilityHelpers.swift` |
| Client Phase 3.5: Section Comments | ✅ Complete | Added to `handleIncomingRequest()` |
| Server Phase 1: Handler State Pattern | ✅ Complete | Created `ServerHandlerRegistry` |
| Server Phase 2: Capability Helpers | ✅ Complete | Created `ServerCapabilityHelpers.swift` |
| Server Phase 3: Handler Wrapping | ✅ Not Needed | Already implemented in `MCPServer.setUpSessionHandlers()` |
| Phase 4: Final Cleanup | ✅ Complete | Merged batching, added debug logging, created ARCHITECTURE.md |

**Server Phase 3 Evaluation**: The spike revealed that handler wrapping at registration time is already implemented in `MCPServer.setUpSessionHandlers()` (lines 299-373). Input validation against `inputSchema` and output validation against `outputSchema` already occur at the right layer. No additional work needed.

See `ARCHITECTURE.md` in the repository root for documentation of architectural decisions.

---

## Background

This plan addresses feedback about the Client and Server implementations having code separation without true separation of responsibility. The ProtocolLayer refactoring (commit 5e05ebb) successfully extracted low-level protocol concerns, but higher-level concerns remain intertwined.

This revised plan takes a more conservative, incremental approach based on architectural review. The TypeScript SDK successfully manages similar complexity within a single ~1600 line Protocol class through well-organized methods, demonstrating that full component extraction may not be necessary. We prioritize targeted fixes over comprehensive restructuring.

**Note**: This is a fork (`DePasqualeOrg/swift-mcp`) focused on finding the optimal design. Backward compatibility is not a constraint—we can make breaking changes to internal APIs, rename types, and restructure freely. The goal is to arrive at the cleanest architecture, which can then inform decisions about migration paths if needed.

## Current Problems

### 1. Code Separation Without Separation of Responsibility

The extension files (`Client+MessageHandling.swift`, `Client+Registration.swift`, `Client+Requests.swift`, etc.) are organized by operation type, not by responsibility. They're tightly coupled through shared state:

- `samplingConfig` is set in `Client+Registration.swift`, read in `Client.swift` during `buildCapabilities()`
- `capabilities` is built in `Client.swift`, validated in `Client+MessageHandling.swift`
- `protocolState` is accessed across multiple extensions

**How this plan addresses it**:
- **Phase 2** consolidates scattered state into a single `ClientHandlerRegistry` struct with an `inferredCapabilities` computed property, making the coupling explicit and focused
- **Phase 3** extracts capability merging/validation logic to `ClientCapabilityHelpers`, giving capability concerns a clear home
- **File reorganization is deferred** because the coupling is about shared state, not file boundaries—Phases 2-3 address the substance (see "Deferred: Extension File Reorganization" section)

### 2. Many Reasons to Update a Single Place

The `connect()` method handles: transport connection, capability building, handler locking, notification stream setup, cancellation registration, and initialization—all in one place (~70 lines). Similarly, `handleIncomingRequest()` mixes validation, routing, handler lookup, context creation, and error handling.

### 3. Progress Callback Encode/Decode Hack

In `Client+Requests.swift`, progress token injection happens through:
```swift
let requestData = try encoder.encode(request)
var requestDict = try decoder.decode([String: Value].self, from: requestData)
// ... inject _meta.progressToken ...
let modifiedRequestData = try encoder.encode(requestDict)
```

This exists because `Request<M>` is immutable and `M.Parameters` is an associated type—we can't generically add `_meta` to any Parameters type.

### 4. Growing Complexity

Task-augmented requests, elicitation mode validation, capability auto-detection, and progress tracking are interleaved throughout the codebase.

---

## Approach: Incremental Improvement Over Component Extraction

After architectural review, we're taking a more conservative approach. The original plan proposed extracting five new components (RequestBuilder, HandlerRegistry, CapabilityBuilder, ConnectionCoordinator, RequestDispatcher), but this risks:

1. **Overengineering** for the actual codebase size (~1300 lines for Client + extensions)
2. **Actor composition complexity** with actor hop costs, complex error propagation, and scattered state
3. **Moving rather than eliminating coupling** (ConnectionCoordinator would still coordinate all the same concerns)

Instead, we'll make targeted improvements within the existing single-actor structure, following the TypeScript SDK's successful pattern of managing complexity through well-organized private methods.

---

## Migration Strategy

### Phase 0: Test Audit (Concrete First PR)

**Goal**: Ensure adequate test coverage exists before refactoring to catch regressions.

**Deliverable**: A PR that adds missing tests. This PR must be merged before any refactoring begins.

**Rationale**: The TypeScript SDK has dedicated test suites for progress token handling, `_meta` preservation, and timeout behavior (`protocol.test.ts` lines 209-450). The Python SDK similarly has `test_176_progress_token.py` and capability inference tests. Before modifying any code, we must verify equivalent coverage exists in Swift.

**Test Audit Checklist**:

Review existing tests in `Tests/MCPTests/` and identify gaps:

| Area | Existing Tests | Gaps to Fill |
|------|----------------|--------------|
| Progress token injection | `ProgressTests.swift` | Verify: `_meta` preservation, requests with no params, existing `progressToken` handling |
| Handler registration | `ClientTests.swift`, `CapabilitiesTests.swift` | Verify: registration before/after connection, capability auto-detection |
| Capability building | `CapabilitiesTests.swift` | Verify: explicit overrides vs auto-detection, validation warnings |
| Request handling | `RequestTests.swift` | Verify: context creation, cancellation-aware responses |
| Elicitation validation | `ElicitationTests.swift` | Verify: mode validation, unsupported mode rejection |

**New Tests Required** (add before refactoring):

```swift
// Progress token injection tests (add to ProgressTests.swift or new file)
@Suite("Progress Token Injection Tests")
struct ProgressTokenInjectionTests {
    @Test("Progress token appears in outgoing request _meta")
    func testProgressTokenInMeta() async throws { /* ... */ }

    @Test("Existing _meta fields are preserved when adding progressToken")
    func testMetaPreservation() async throws { /* ... */ }

    @Test("Requests with no params get _meta.progressToken added")
    func testNoParamsRequest() async throws { /* ... */ }

    @Test("Existing progressToken is overwritten by SDK-generated token")
    func testExistingProgressTokenOverwritten() async throws { /* ... */ }

    @Test("Progress handler survives CreateTaskResult in batch requests")
    func testProgressHandlerSurvivesTaskResultInBatch() async throws { /* ... */ }

    @Test("Multiple requests in batch each with own progress callback")
    func testBatchWithMultipleProgressCallbacks() async throws { /* ... */ }

    @Test("Concurrent progress notifications don't race with cleanup")
    func testConcurrentProgressNotificationsNoRace() async throws { /* ... */ }
}

// Handler state tests (add to ClientTests.swift)
@Test("Handler registration rejected after connection")
func testHandlerRegistrationRejectedAfterConnect() async throws { /* ... */ }

@Test("Capability config affects advertised capabilities")
func testCapabilityConfigAffectsAdvertised() async throws { /* ... */ }

@Test("Repeated registration of same handler type overwrites previous")
func testRepeatedRegistrationOverwrites() async throws { /* ... */ }

@Test("Registration order doesn't affect capability inference")
func testRegistrationOrderIndependent() async throws { /* ... */ }
```

**MockTransport Enhancement**:

Verify `InMemoryTransport` supports inspecting sent messages. If not, consider adding a test helper:

```swift
/// Test helper that captures raw JSON messages for inspection.
actor MessageCapturingTransport: Transport {
    private(set) var sentMessages: [Data] = []
    private let underlying: InMemoryTransport

    func send(_ data: Data) async throws {
        sentMessages.append(data)
        try await underlying.send(data)
    }

    /// Decode the last sent message for inspection.
    func lastSentJSON() throws -> [String: Value]? {
        guard let data = sentMessages.last else { return nil }
        return try JSONDecoder().decode([String: Value].self, from: data)
    }
}
```

**Success Criteria**:
- [ ] All test areas above have corresponding tests
- [ ] Tests pass before refactoring begins
- [ ] Any gaps identified are filled with new tests

---

### Phase 1: Fix Progress Token Injection (High Priority, Low Risk)

**Goal**: Eliminate the encode-decode-mutate-encode hack.

**SDK Research Findings**:

Both TypeScript and Python SDKs use **request/message ID as the progress token**:

```typescript
// TypeScript: Protocol.request() lines 1121-1129
if (options?.onprogress) {
    this._progressHandlers.set(messageId, options.onprogress);
    jsonrpcRequest.params = {
        ...request.params,
        _meta: { ...request.params?._meta, progressToken: messageId }
    };
}
```

```python
# Python: BaseSession.send_request() lines 252-261
if progress_callback is not None:
    request_data["params"]["_meta"]["progressToken"] = request_id
    self._progress_callbacks[request_id] = progress_callback
```

Both inject the progress token **before** the final JSON-RPC message is constructed. TypeScript uses object spread; Python mutates the dict after `model_dump()` but before creating `JSONRPCRequest`.

**Recommended Approach**: Centralize injection in ProtocolLayer

Both TypeScript and Python put progress token injection at the base protocol/session layer (not in client-specific code). We follow this pattern by centralizing the decode-mutate-encode in `ProtocolLayer`.

**Why ProtocolLayer (not Client+Requests.swift)**:

1. **Matches SDK architecture**: TypeScript's `Protocol.request()` and Python's `BaseSession.send_request()` both handle this at the protocol layer
2. **Single injection point**: Any code path that sends requests with progress automatically gets the injection
3. **Future extensibility**: Other metadata injection (task augmentation, related request IDs) can use the same mechanism

**Implementation approach**: Add an optional `metaValues` parameter to the existing `sendProtocolRequest` interface:

```swift
// In ProtocolLayer - extend existing sendProtocolRequest
func sendProtocolRequest(
    _ request: Data,
    requestId: RequestId,
    options: ProtocolRequestOptions,
    metaValues: [String: Value]? = nil  // NEW: inject into params._meta
) async throws -> Data {
    var requestData = request

    // Inject metadata values if provided
    if let metaValues {
        requestData = try injectMeta(into: requestData, values: metaValues)
    }

    // ... rest of existing implementation
}

/// Injects metadata values into the _meta field of a JSON-RPC request.
/// This is the single location for the decode-mutate-encode pattern.
///
/// Error handling: If decoding fails (malformed request data), logs the error and throws
/// `MCPError.internalError`. This follows the existing pattern for encode/decode failures
/// throughout the codebase. Logging before throwing aids debugging of unexpected failures.
private func injectMeta(into requestData: Data, values: [String: Value]) throws -> Data {
    do {
        var dict = try JSONDecoder().decode([String: Value].self, from: requestData)
        var params = dict["params"]?.objectValue ?? [:]
        var meta = params["_meta"]?.objectValue ?? [:]
        for (key, value) in values {
            meta[key] = value
        }
        params["_meta"] = .object(meta)
        dict["params"] = .object(params)
        return try JSONEncoder().encode(dict)
    } catch {
        logger?.error("Failed to inject metadata into request", metadata: ["error": "\(error)"])
        throw MCPError.internalError("Failed to inject metadata: \(error)")
    }
}
```

**Note**: We keep the existing `Data`-based interface rather than accepting typed `Request<M>`. This avoids API changes to ProtocolLayer while still centralizing the injection logic. The caller (Client+Requests.swift) encodes the request, then ProtocolLayer optionally injects metadata before sending.

**Key Design Decision**: Use request ID as progress token (matching TypeScript/Python). This provides a natural, deterministic mapping without needing separate token generation.

**Batch Request Handling**: Both SDKs handle batch requests by injecting progress tokens per-request within the batch. The TypeScript SDK's `_onrequest()` processes each request in a batch individually, each with its own message ID and potential progress token. Our implementation should follow this pattern—batch handling happens at the transport level, but progress injection operates on individual requests.

**Progress Token Overwrite Behavior**: Per TypeScript SDK behavior (lines 1123-1129), any user-provided `_meta.progressToken` is overwritten by the SDK-generated token (the request ID). This is intentional—the SDK controls progress tracking. Other `_meta` fields are preserved via spread/merge.

**Spike Acceptance Criteria**:

Before committing to the implementation, verify:

1. **Correctness**: Progress tokens appear in outgoing requests correctly
2. **Preservation**: Existing `_meta` fields (other than `progressToken`) are preserved
3. **Overwrite**: User-provided `progressToken` is replaced by request ID (matching TypeScript behavior)
4. **Edge cases**: Requests with no params, requests with existing `_meta`
5. **Batch behavior**: Progress injection works correctly within batched requests
6. **Task lifecycle**: Progress handlers survive `CreateTaskResult` responses (for task-augmented requests)
7. **Performance**: Benchmark against current approach (expect negligible difference for typical request sizes)

**Files Changed**: `Sources/MCP/Base/ProtocolLayer.swift`, `Sources/MCP/Client/Client+Requests.swift`

**Success Criteria**:
- No encode-decode-mutate pattern in `Client+Requests.swift`
- Progress injection handled entirely within ProtocolLayer via `injectMeta()`
- Clean API for callers (just pass `progressToken` parameter)
- Request ID used as progress token (matching TypeScript/Python pattern)

### Phase 2: Consolidate Handler State (Medium Priority, Low Risk)

**Goal**: Reduce scattered state by grouping related handler data into a single cohesive struct.

**Approach**: Create a single `ClientHandlerRegistry` struct that owns both handlers AND their configuration, with an `inferredCapabilities` computed property.

**Rationale for Single Struct** (revised from original two-struct proposal):

The original plan proposed separate `ClientHandlerRegistry` and `CapabilityConfiguration` structs, but architectural review revealed:
- `samplingConfig`, `elicitationConfig`, `rootsConfig` are set during handler registration
- These configs exist solely to derive capabilities
- Separating them creates artificial boundaries between tightly related data

Merging them into one struct with a computed property keeps related data together and makes the capability inference explicit:

```swift
/// Registry of handlers and their configuration for responding to server requests/notifications.
/// Named "Registry" rather than "Handlers" because it contains both handlers AND configuration
/// that affects capability inference.
struct ClientHandlerRegistry: Sendable {
    // --- Handlers ---

    /// Notification handlers keyed by method name.
    var notificationHandlers: [String: [NotificationHandlerBox]] = [:]

    /// Request handlers keyed by method name.
    var requestHandlers: [String: ClientRequestHandlerBox] = [:]

    /// Task-augmented sampling handler (experimental).
    var taskAugmentedSamplingHandler: ExperimentalClientTaskHandlers.TaskAugmentedSamplingHandler?

    /// Task-augmented elicitation handler (experimental).
    var taskAugmentedElicitationHandler: ExperimentalClientTaskHandlers.TaskAugmentedElicitationHandler?

    // --- Handler Configuration (affects inferred capabilities) ---

    var samplingConfig: SamplingConfig?
    var elicitationConfig: ElicitationConfig?
    var rootsConfig: RootsConfig?
    var tasksConfig: Capabilities.Tasks?

    // --- State ---

    /// Whether handler registration is locked (after connection).
    var isLocked = false

    // --- Computed Capabilities ---

    /// Infer capabilities from registered handlers and their configuration.
    /// This is used during `connect()` to build the client's advertised capabilities.
    ///
    /// This follows the Python SDK's `ExperimentalTaskHandlers.build_capability()` pattern
    /// where capability presence is inferred from which handlers are registered.
    var inferredCapabilities: Client.Capabilities {
        var caps = Client.Capabilities()

        if let samplingConfig {
            caps.sampling = .init(
                supportsContext: samplingConfig.supportsContext,
                supportsTools: samplingConfig.supportsTools
            )
        }

        if let elicitationConfig {
            caps.elicitation = .init(
                formMode: elicitationConfig.formMode.map { .init(/* ... */) },
                urlMode: elicitationConfig.urlMode.map { .init(/* ... */) }
            )
        }

        if let rootsConfig {
            caps.roots = .init(listChanged: rootsConfig.listChanged)
        }

        // Tasks capability: use explicit config if provided, otherwise infer from handlers.
        // This matches Python SDK's pattern where task-augmented handler presence
        // determines capability advertisement.
        //
        // Design note: This intentionally mixes "explicit config" with "handler-based inference"
        // because tasks capability has dual semantics:
        // - If user explicitly sets tasksConfig, respect their configuration
        // - If not set, infer from registered task-augmented handlers
        // This is different from sampling/elicitation/roots where config is always set during
        // handler registration. If this mixing becomes confusing, consider moving tasksConfig
        // handling to ClientCapabilityHelpers.merge() as an explicit override.
        if let tasksConfig {
            caps.tasks = tasksConfig
        } else if taskAugmentedSamplingHandler != nil || taskAugmentedElicitationHandler != nil {
            // Infer tasks.requests capability from registered task-augmented handlers
            var requestsCap = Capabilities.Tasks.Requests()
            if taskAugmentedSamplingHandler != nil {
                requestsCap.sampling = .init(createMessage: .init())
            }
            if taskAugmentedElicitationHandler != nil {
                requestsCap.elicitation = .init(create: .init())
            }
            caps.tasks = .init(requests: requestsCap)
        }

        return caps
    }
}
```

**Migration Path**:

```swift
// Before (scattered properties)
actor Client {
    var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    var requestHandlers: [String: ClientRequestHandlerBox] = [:]
    var taskAugmentedSamplingHandler: ...?
    var samplingConfig: SamplingConfig?
    var elicitationConfig: ElicitationConfig?
    // ... more scattered state
}

// After (grouped state)
actor Client {
    var registeredHandlers = ClientHandlerRegistry()
}
```

**Benefits**:
- All handler-related data in one place
- Capability inference is explicit via computed property
- Still within Client actor's isolation (no actor hop costs)
- Extensions access one focused struct instead of many scattered properties
- Easy to test: create a `ClientHandlerRegistry`, check its `inferredCapabilities`

**Files Changed**: `Sources/MCP/Client/Client.swift`, `Sources/MCP/Client/Client+Registration.swift`, `Sources/MCP/Client/Client+MessageHandling.swift`

**Success Criteria**:
- All handler-related state accessed through `registeredHandlers`
- Capability inference explicit via `registeredHandlers.inferredCapabilities`
- `buildCapabilities()` merges inferred capabilities with explicit overrides

### Phase 3: Extract Capability Helpers (Medium Priority, Low Risk)

**Goal**: Move capability merging and validation to static helpers for clarity.

**Approach**: Use an enum namespace with static functions. With the single-struct approach from Phase 2, these helpers focus on **merging** inferred capabilities with explicit overrides, and **validating** consistency.

```swift
/// Helpers for building and validating client capabilities.
enum ClientCapabilityHelpers {
    /// Merge inferred capabilities with explicit overrides.
    /// Explicit overrides take precedence where provided.
    static func merge(
        inferred: Client.Capabilities,
        explicit: Client.Capabilities?
    ) -> Client.Capabilities {
        guard let explicit else { return inferred }

        var capabilities = inferred

        // Explicit overrides win
        if explicit.sampling != nil {
            capabilities.sampling = explicit.sampling
        }
        if explicit.elicitation != nil {
            capabilities.elicitation = explicit.elicitation
        }
        if explicit.roots != nil {
            capabilities.roots = explicit.roots
        }
        if explicit.tasks != nil {
            capabilities.tasks = explicit.tasks
        }
        // ... experimental, etc.

        return capabilities
    }

    /// Validate that advertised capabilities have handlers registered.
    static func validate(
        _ capabilities: Client.Capabilities,
        handlers: ClientHandlerRegistry,
        logger: Logger?
    ) {
        // Warning checks for advertised but unhandled capabilities
        if capabilities.sampling != nil && handlers.requestHandlers[CreateSamplingMessage.name] == nil {
            logger?.warning("Sampling capability advertised but no handler registered")
        }
        if capabilities.elicitation != nil && handlers.requestHandlers[Elicit.name] == nil {
            logger?.warning("Elicitation capability advertised but no handler registered")
        }
        if capabilities.roots != nil && handlers.requestHandlers[ListRoots.name] == nil {
            logger?.warning("Roots capability advertised but no handler registered")
        }
    }
}
```

**Usage in Client**:

```swift
// In connect()
let inferred = registeredHandlers.inferredCapabilities
capabilities = ClientCapabilityHelpers.merge(inferred: inferred, explicit: explicitCapabilities)
ClientCapabilityHelpers.validate(capabilities, handlers: registeredHandlers, logger: logger)
```

**Benefits**:
- Capability merging logic extracted from `Client.swift`
- Validation logic explicit and testable
- Pure functions with explicit inputs—easy to test in isolation
- No actor overhead or coordination complexity

**Files Changed**: New file `Sources/MCP/Client/ClientCapabilityHelpers.swift`, updates to `Sources/MCP/Client/Client.swift`

**Success Criteria**: Capability merging and validation logic centralized in testable static helpers.

### Phase 3.5: Clarify Request Handling Flow (Medium Priority, Zero Risk)

**Goal**: Make `handleIncomingRequest()` easier to understand without over-extracting.

**Timing Note**: This phase adds only section comments—zero code changes. It can be done at any time, even before Phase 2, or as a quick improvement during any PR touching `Client+MessageHandling.swift`.

**SDK Research Findings**:

TypeScript's `_onrequest()` (~150 lines in `protocol.ts:677-829`) and Python's `_handle_request()` (~76 lines in `server.py:732-808`) keep request handling in a single method with clear internal structure. Neither SDK extracts context creation or response handling into separate methods.

The current Swift implementation (`Client+MessageHandling.swift:117-233`) is ~116 lines—comparable to the reference implementations. The complexity is manageable.

**Revised Approach: Section Comments Over Method Extraction**

Rather than extracting `makeRequestHandlerContext()` and `executeAndRespond()` (which the architectural review noted "saves ~40 lines but adds two new methods plus the original reduced method—net complexity is similar; navigation is harder"), we use clear section comments to document the flow:

```swift
func handleIncomingRequest(_ request: Request<AnyMethod>) async {
    // --- Logging ---
    logger?.trace(
        "Processing incoming request from server",
        metadata: ["method": "\(request.method)", "id": "\(request.id)"]
    )

    // --- Pre-dispatch validation ---
    // Elicitation mode validation requires runtime capabilities, so it stays at dispatch time
    if request.method == Elicit.name {
        if let modeError = await validateElicitationMode(request) {
            await sendResponse(modeError)
            return
        }
    }

    // --- Task-augmented routing ---
    // Check for task-augmented sampling/elicitation requests before normal handling
    if let taskResponse = await handleTaskAugmentedRequest(request) {
        await sendResponse(taskResponse)
        return
    }

    // --- Handler lookup ---
    guard let handler = registeredHandlers.requestHandlers[request.method] else {
        logger?.warning("No handler registered for server request", metadata: ["method": "\(request.method)"])
        let response = AnyMethod.response(
            id: request.id,
            error: MCPError.methodNotFound("Client has no handler for: \(request.method)")
        )
        await sendResponse(response)
        return
    }

    // --- Context creation ---
    let requestMeta = extractMeta(from: request.params)
    let context = RequestHandlerContext(
        sessionId: nil,
        requestId: request.id,
        _meta: requestMeta,
        // ... rest of context creation
    )

    // --- Execution with cancellation awareness ---
    do {
        let response = try await handler(request, context: context)
        if !Task.isCancelled {
            await sendResponse(response)
        }
    } catch {
        if !Task.isCancelled {
            // ... error handling
        }
    }
}
```

**When to Revisit This Decision**:

Only extract methods if:
1. Context creation is needed in multiple places (currently only used here)
2. The method grows beyond ~150 lines (matching TypeScript's threshold)
3. Testing individual sections becomes difficult

**What CAN move to registration time** (for Server, not Client):

The TypeScript pattern (`Server.setRequestHandler()` lines 255-301) wraps `tools/call` handlers at registration time to validate input/output schemas. This is applicable to **Server** but not Client:
- Client handlers have simpler validation needs covered by the type system
- Elicitation mode validation requires runtime access to `capabilities.elicitation`

**Files Changed**: `Sources/MCP/Client/Client+MessageHandling.swift` (section comments only)

**Success Criteria**:
- `handleIncomingRequest()` has clear section comments documenting the flow
- No unnecessary method extraction
- Linear flow preserved: validate → route → lookup → context → execute

### Phase 4: Evaluate and Iterate

After completing Phases 1-3.5, reassess the codebase:

1. **Is the progress injection clean?** If yes, Phase 1 succeeded.
2. **Is handler state easier to navigate?** If yes, Phase 2 succeeded.
3. **Is capability logic clear and testable?** If yes, Phase 3 succeeded.
4. **Is request handling simplified?** If yes, Phase 3.5 succeeded.
5. **Are there remaining pain points?** If so, consider targeted additional improvements.

**Evaluation Checklist**:

- [ ] Progress token injection uses request ID, centralized in ProtocolLayer
- [ ] Handler state accessed through focused structs
- [ ] Capability helpers are pure functions with tests
- [ ] `handleIncomingRequest()` flow is clear: validate → route → lookup → context → execute
- [ ] Context creation extracted to helper
- [ ] Test coverage improved for refactored areas

**Phase 4 Candidate: `connect()` Decomposition**

The `connect()` method in `Client.swift:366-434` handles multiple responsibilities (~70 lines):

1. Build capabilities from handlers and explicit overrides
2. Validate capabilities
3. Lock handler registration
4. Connect transport
5. Set up notification dispatch stream (with cleanup of previous stream)
6. Configure close callback
7. Start protocol message loop
8. Register cancellation notification handler (with duplicate guard)
9. Run initialization handshake

**TypeScript comparison**: The TypeScript `Protocol.connect()` (lines 611-639) is simpler (~30 lines) because:
- It only sets up transport callbacks and starts the transport
- Initialization is separate in `Client.connect()` which calls `super.connect()` then `this.request(initialize)`
- There's no notification dispatch stream setup (JS uses Promise.resolve().then())

**Concrete Trigger**: Extract private helpers if any of these occur:
- `connect()` exceeds 100 lines
- A new step needs to be inserted into the middle of the method (breaking the sequential flow)
- Adding a new responsibility requires understanding unrelated steps

```swift
public func connect(transport: any Transport) async throws -> Initialize.Result {
    // 1. Prepare client state
    prepareForConnection()

    // 2. Connect transport
    try await transport.connect()
    protocolLogger = await transport.logger
    logger?.debug("Client connected", metadata: ["name": "\(name)", "version": "\(version)"])

    // 3. Set up notification dispatch
    setupNotificationDispatchStream()

    // 4. Configure callbacks and start protocol
    configureCloseCallback()
    startProtocolOnConnectedTransport(transport)
    registerCancellationHandlerIfNeeded()

    // 5. Initialize
    return try await _initialize()
}

private func prepareForConnection() {
    capabilities = buildCapabilities()
    await validateCapabilities(capabilities)
    handlersLocked = true
}

private func setupNotificationDispatchStream() {
    notificationContinuation?.finish()
    notificationTask?.cancel()

    let (stream, continuation) = AsyncStream<Message<AnyNotification>>.makeStream()
    notificationContinuation = continuation
    notificationTask = Task { /* dispatch loop */ }
}

private func registerCancellationHandlerIfNeeded() {
    guard !cancelledNotificationRegistered else { return }
    cancelledNotificationRegistered = true
    onNotification(CancelledNotification.self) { /* handler */ }
}
```

**Decision criteria**: Only extract if:
- Future changes to `connect()` become difficult due to interleaved concerns
- Testing `connect()` requires mocking too many things at once
- Reconnection logic (MCPClient) needs to reuse parts of `connect()`

**Phase 4 Action Items** (concrete deliverables):

1. **Merge `Client+Batching.swift` into `Client+Requests.swift`**: Both files concern outgoing requests. Separating batching (~146 lines) adds navigation overhead without separation of responsibility. This is the only clear file reorganization improvement.

2. **Create `ARCHITECTURE.md`**: Document the architectural decisions made during this refactoring:
   - Why single-actor over multi-actor
   - Why static helpers over protocol abstractions
   - The progress token injection pattern and its necessity (Swift's type system constraints)
   - How capability auto-detection works
   - Handler wrapping patterns (Server only for tools/call)

   This helps future maintainers understand the "why" behind the architecture.

   **Note**: While ARCHITECTURE.md is created in Phase 4, each phase's PR description should capture key decisions as they're made. This provides immediate documentation and makes the final ARCHITECTURE.md easier to write by consolidating PR descriptions.

3. **Add debug logging for `inferredCapabilities`**: Add trace-level logging when capabilities are inferred to help developers troubleshoot capability mismatch issues. Log which handlers contributed to which capabilities.

**Other Possible Phase 4 improvements** (only if needed):

- **Extension file reorganization beyond batching**: Evaluate after Phases 2-3 if file organization still feels problematic. The substantive coupling issues should be addressed by state consolidation. See "Deferred: Extension File Reorganization" section for detailed analysis.

- **Add more comprehensive integration tests** covering full flows
- **Shared RequestHandlerContext factory** (only if Client/Server patterns converge after refactoring)

**Do not proceed with** full component extraction (ConnectionCoordinator, RequestDispatcher as separate actors) unless Phase 4 evaluation reveals specific problems that require it.

---

## Server Refactoring Plan

The Server has similar but less severe issues. The feedback noted issues are "not so major," but the architectural review identified specific areas that warrant attention.

### Server Issues Identified

1. **`handleRequest` method complexity**: At ~178 lines, it handles multiple responsibilities (validation, routing, handler lookup, context creation, error handling)

2. **RequestHandlerContext creation duplication**: Both Client (`Client+MessageHandling.swift:161-191`) and Server (`Server+RequestHandling.swift:249-299`) create `RequestHandlerContext` with similar closure patterns

3. **RequestContext struct mixing concerns**: The Server's `RequestContext` mixes transport concerns with request metadata

### Server Refactoring Timing

**Recommendation**: Add a decision point after Client Phase 3 to evaluate interleaving vs. batching.

**Initial sequence** (interleaved approach):
1. Client Phase 1 (progress injection)
2. Client Phase 2 (handler state consolidation)
3. **Server Phase 1** (handler state pattern)
4. Client Phase 3 (capability helpers)
5. **Server Phase 2** (capability helpers)
6. Client Phase 3.5 (request handling clarity)
7. **Server Phase 3** (handler wrapping at registration)
8. Client Phase 4 + **Server Phase 4** (evaluation)

**Decision Point After Client Phase 3**:

After completing Client Phases 1-3, evaluate:
- Has the pattern stabilized? Are we confident in the approach?
- Were there unexpected issues that would change the Server approach?

If the pattern is stable, consider **batching** Server Phases 1-3 into a single PR. This:
- Reduces context switching
- Allows applying all lessons from Client at once
- Avoids Server looking "half-refactored" between phases

**Criteria for batching**:
- Client Phases 1-3 completed without major issues
- No significant pattern changes discovered during Client refactoring
- Server changes are straightforward application of proven patterns

### Server Refactoring Phases

#### Server Phase 1: Apply Handler State Pattern

Mirror the Client's single-struct approach with `inferredCapabilities`:

```swift
struct ServerHandlerRegistry: Sendable {
    // --- Handlers ---
    var toolHandlers: [String: ToolHandler] = [:]
    var resourceHandlers: [String: ResourceHandler] = [:]
    var promptHandlers: [String: PromptHandler] = [:]
    // ...

    // --- Handler Configuration ---
    var toolsCapabilityConfig: ToolsCapabilityConfig?
    var resourcesCapabilityConfig: ResourcesCapabilityConfig?
    var promptsCapabilityConfig: PromptsCapabilityConfig?
    // ...

    var isLocked = false

    // --- Computed Capabilities ---
    var inferredCapabilities: Server.Capabilities {
        var caps = Server.Capabilities()

        if !toolHandlers.isEmpty || toolsCapabilityConfig != nil {
            caps.tools = .init(listChanged: toolsCapabilityConfig?.listChanged ?? false)
        }
        // ... similar for resources, prompts

        return caps
    }
}
```

#### Server Phase 2: Extract ServerCapabilityHelpers

Mirror the Client's helper pattern:

```swift
enum ServerCapabilityHelpers {
    static func merge(
        inferred: Server.Capabilities,
        explicit: Server.Capabilities?
    ) -> Server.Capabilities

    static func validate(
        _ capabilities: Server.Capabilities,
        handlers: ServerHandlerRegistry,
        logger: Logger?
    )
}
```

#### Server Phase 3: Handler Wrapping at Registration (tools/call Only)

**This is the key difference from Client Phase 3.5**: Server handlers benefit from registration-time wrapping for schema validation.

**TypeScript Pattern** (`Server.setRequestHandler()` lines 255-301):

```typescript
if (method === 'tools/call') {
    const wrappedHandler = async (request, extra) => {
        // 1. Validate input request against CallToolRequestSchema
        const validatedRequest = safeParse(CallToolRequestSchema, request);
        if (!validatedRequest.success) {
            throw new McpError(ErrorCode.InvalidParams, `Invalid tools/call request: ${errorMessage}`);
        }

        // 2. Execute the actual handler
        const result = await Promise.resolve(handler(request, extra));

        // 3. Validate output based on whether task creation was requested
        if (params.task) {
            // Validate against CreateTaskResultSchema
            const taskValidationResult = safeParse(CreateTaskResultSchema, result);
            if (!taskValidationResult.success) {
                throw new McpError(ErrorCode.InvalidParams, `Invalid task creation result: ${errorMessage}`);
            }
            return taskValidationResult.data;
        }

        // 4. For non-task requests, validate against CallToolResultSchema
        const validationResult = safeParse(CallToolResultSchema, result);
        if (!validationResult.success) {
            throw new McpError(ErrorCode.InvalidParams, `Invalid tools/call result: ${errorMessage}`);
        }
        return validationResult.data;
    };
    return super.setRequestHandler(requestSchema, wrappedHandler);
}
```

**Swift Adaptation**:

```swift
// Wrap tools/call handler with validation at registration
func registerToolHandler(
    name: String,
    inputSchema: Value?,  // JSON Schema for input validation
    handler: @escaping ToolHandler
) {
    let wrappedHandler: ToolHandlerBox = { [validator] request, context in
        // 1. Input validation (if schema provided)
        if let inputSchema {
            try validator.validate(request.params.arguments, against: inputSchema)
        }

        // 2. Execute handler
        let result = try await handler(request, context)

        // 3. Output validation
        // - If task creation requested: validate CreateTaskResult
        // - Otherwise: validate CallToolResult
        // (The type system handles most of this in Swift)

        return result
    }
    registeredHandlers.toolHandlers[name] = wrappedHandler
}
```

**What This Achieves**:
- Input schema validation happens at registration time (not repeated at dispatch)
- Output validation is consistent across all tool calls
- Dispatch logic stays simple—just lookup and call
- Matches TypeScript SDK's pattern exactly

**Spike Required Before Full Implementation**:

**Note**: Swift already has a working `DefaultJSONSchemaValidator` using `swift-json-schema` (draft-2020-12) with schema caching. TypeScript's `safeParse` (in `zodCompat.ts`) is for Zod type validation, not JSON Schema—their JSON Schema validation uses separate `AjvJsonSchemaValidator` or `CfWorkerJsonSchemaValidator` classes. The spike should focus on **API design**, not validation capability.

The spike should answer:

1. **API design for per-tool schema registration**:
   - Should schemas come from tool definitions (via `tools/list` `inputSchema`)?
   - Or require explicit registration with each handler?
   - How to handle tools without schemas (skip validation)?

2. **Validation scope**:
   - Input validation only? Or also output validation against `outputSchema`?
   - The TypeScript SDK validates both; decide if Swift should match.

3. **Applicability to other handlers**:
   - Briefly evaluate whether `prompts/get` or `resources/read` handlers would benefit from similar wrapping
   - Expected answer is "no" (they lack input schemas and have simpler result types), but confirm this assumption

4. **Verification**:
   - Test `DefaultJSONSchemaValidator` against 3-4 common tool input patterns (nested objects, arrays, required/optional fields)
   - Verify schema caching works correctly for repeated tool calls

5. **Error messaging**:
   - Ensure validation errors are clear and actionable

If the spike reveals API design issues, evaluate whether:
- Dispatch-time validation is acceptable for Server (matching Client pattern)
- A phased approach (input validation first, output validation later) makes sense

**Note on RequestHandlerContext**: Unlike the original plan's proposal to extract context creation, we follow the same approach as Client Phase 3.5—use section comments, not method extraction. The Server's context is more complex (includes `closeResponseStream`, `closeNotificationStream`, `sendData`, `shouldSendLogMessage`, `serverCapabilities`), but not complex enough to warrant extraction unless reuse emerges.

#### Server Phase 4: Evaluate

Same evaluation criteria as Client Phase 4, plus:
- Is tool/resource/prompt handler registration clean?
- Is validation happening at the right time (registration vs dispatch)?

---

## Test Coverage Strategy

**Principle**: Audit existing coverage before refactoring; add tests first if coverage is low (test-before-refactor pattern).

### SDK Test Organization Patterns

**TypeScript SDK** (`packages/core/test/shared/protocol.test.ts`):

1. **Mock Transport** for unit tests:
```typescript
class MockTransport implements Transport {
    onclose?: () => void;
    onmessage?: (message: unknown) => void;
    async send(_message: JSONRPCMessage): Promise<void> {}
}
```

2. **Progress Token Tests** (lines 209-361):
   - Tests `_meta` preservation (existing fields not overwritten)
   - Tests params handling (requests with/without params)
   - Tests timeout behavior with progress handlers
   - Tests task lifecycle (progress handlers survive CreateTaskResult)

3. **Integration Tests** (`test/integration/test/`):
   - Full client-server flows with real transports
   - Task lifecycle end-to-end tests

**Python SDK** (`tests/`):

1. **Memory Stream Setup** for isolated tests:
```python
server_to_client_send, server_to_client_receive = anyio.create_memory_object_stream[SessionMessage](1)
```

2. **Capability Inference Tests** (lines 87-133 of `test_session.py`):
   - Tests that capabilities are correctly inferred from registered handlers

3. **Validation Tests** (`test_lowlevel_input_validation.py`, `test_lowlevel_output_validation.py`):
   - Input schema validation
   - Output schema validation

### Tests Required Before Refactoring

**Phase 1 (Progress Injection)**:
- [ ] Test progress token appears in outgoing request `_meta`
- [ ] Test existing `_meta` fields are preserved
- [ ] Test requests with no params
- [ ] Test requests with existing `_meta.progressToken` (should override? preserve?)
- [ ] Test progress handler receives notifications correctly
- [ ] Test progress handler cleanup on request completion
- [ ] Test task-augmented request progress lifecycle
- [ ] Test multiple requests in batch each with own progress callback

**Phase 2 (Handler State Consolidation)**:
- [ ] Test handler registration before connection
- [ ] Test handler registration rejected after connection (if `isLocked`)
- [ ] Test capability config affects advertised capabilities

**Phase 3 (Capability Helpers)**:
- [ ] Test capability building from config (each capability type)
- [ ] Test explicit capabilities override auto-detected
- [ ] Test validation warnings for mismatched capabilities/handlers

**Phase 3.5 (Request Handling Decomposition)**:
- [ ] Test handler wrapping applies validation
- [ ] Test context creation includes correct closures
- [ ] Test error propagation through wrapped handlers

### Test Infrastructure Additions

Consider adding a `MockTransport` if not already present:

```swift
/// A transport for testing that captures sent messages and allows injecting responses.
actor MockTransport: Transport {
    var sentMessages: [Data] = []
    var onMessage: ((Data) async -> Void)?

    func send(_ data: Data) async throws {
        sentMessages.append(data)
    }

    func start() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.onMessage = { data in
                continuation.yield(data)
            }
        }
    }

    func close() async {}

    // Test helper: inject a response
    func injectResponse(_ data: Data) async {
        await onMessage?(data)
    }
}
```

---

## Future Considerations

These are not planned for the current refactoring but are noted for future reference.

### Interceptor Pattern for Cross-Cutting Concerns

The task-augmented handler pattern (`handleTaskAugmentedRequest` in `Client+MessageHandling.swift:276-326`) uses if-else chains to detect and route special requests. As MCP evolves, more features may need similar patterns.

If this becomes a pain point, consider a middleware/interceptor pattern:

```swift
/// Interceptors can modify or handle requests before the main handler.
protocol RequestInterceptor: Sendable {
    func intercept<M: Method>(
        _ request: Request<M>,
        context: RequestHandlerContext,
        next: @Sendable (Request<M>, RequestHandlerContext) async throws -> M.Result
    ) async throws -> M.Result
}

// Example: TaskAugmentedInterceptor
struct TaskAugmentedInterceptor: RequestInterceptor {
    func intercept<M: Method>(...) async throws -> M.Result {
        if isTaskAugmented(request) {
            return try await handleTaskAugmented(request, context: context)
        }
        return try await next(request, context)
    }
}
```

This is not currently justified but provides an evolution path if the if-else chain grows.

### Architecture Documentation

The decisions to avoid multiple actors and protocol-based abstractions are valuable architectural knowledge. **This is now a Phase 4 deliverable**: create `ARCHITECTURE.md` to document:
- Why single-actor over multi-actor
- Why static helpers over protocol abstractions
- The progress token injection pattern and its necessity
- How capability auto-detection works
- Handler wrapping patterns (Server only for tools/call)

---

## What We're NOT Doing (And Why)

### Rejected: Multiple Actor Components

The original plan proposed HandlerRegistry, ConnectionCoordinator, and RequestDispatcher as separate actors. This would:

- Add actor hop costs for every cross-component call
- Scatter state across multiple isolation contexts
- Complicate error handling and debugging
- Move complexity rather than reduce it

The TypeScript SDK demonstrates this isn't necessary—their Protocol class manages all these concerns in one place with good method organization.

### Rejected: Full RequestBuilder Type

A dedicated `RequestBuilder<M>` type adds a new public API surface. Instead, we handle progress injection at the protocol layer where it naturally belongs—during JSON-RPC message construction.

### Rejected: Protocol-Based Abstractions

Defining protocols like `HandlerRegistering` or `CapabilityBuilding` adds abstraction without benefit. We don't need to swap implementations.

### Deferred: Extension File Reorganization

The feedback identified that "The code is split into different extensions, but they're still coupled with each other—it's code separation, not separation of responsibility."

**Current extension structure** (by operation type):

| File | Lines | Purpose |
|------|-------|---------|
| `Client.swift` | ~670 | Core actor, connect/disconnect, capability building |
| `Client+MessageHandling.swift` | ~367 | Incoming message dispatch, validation |
| `Client+Registration.swift` | ~350 | Handler registration APIs |
| `Client+Requests.swift` | ~345 | Outgoing requests with progress |
| `Client+ProtocolMethods.swift` | ~226 | MCP protocol method wrappers (listTools, etc.) |
| `Client+Tasks.swift` | ~235 | Experimental task support |
| `Client+Batching.swift` | ~146 | Batched request support |

**The coupling problem**: Extensions access shared state across files:
- `samplingConfig` set in Registration, read in Client.swift
- `capabilities` built in Client.swift, validated in MessageHandling
- `protocolState` accessed everywhere

**Why reorganizing files doesn't solve this**:

1. **The coupling is about shared state, not file boundaries**. Even if we renamed `Client+Registration.swift` to `Client+Setup.swift`, it would still need to access `samplingConfig` and set it so `buildCapabilities()` can read it.

2. **Phase 2 addresses the substance of the coupling**. By consolidating state into a single `ClientHandlerRegistry` struct with `inferredCapabilities`, the scattered property access becomes focused struct access. This is the real fix.

3. **Phase 3 extracts capability logic**. The `ClientCapabilityHelpers` enum centralizes capability merging and validation, addressing the scattered capability code.

**What reorganization WOULD look like** (for reference):

| Current | By Responsibility | Notes |
|---------|-------------------|-------|
| `Client+MessageHandling.swift` | Keep | Clear responsibility: incoming messages |
| `Client+Registration.swift` | Keep | Clear responsibility: handler setup |
| `Client+Requests.swift` | Keep | Clear responsibility: outgoing requests |
| `Client+Batching.swift` | Merge into `Client+Requests.swift` | Both are about outgoing requests |
| `Client+ProtocolMethods.swift` | Keep | Clear responsibility: MCP API wrappers |
| `Client+Tasks.swift` | Keep | Clear responsibility: experimental features |

**Recommendation**: After Phases 2-3 are complete, evaluate whether file organization still feels problematic. The state consolidation may make the current file structure feel more natural. If not, the only clear improvement is merging `Client+Batching.swift` into `Client+Requests.swift` (~146 lines is small enough to absorb).

**What we're NOT doing**:
- Creating a `Client+Capabilities.swift` extension (Phase 3's `ClientCapabilityHelpers.swift` is better—it's a separate enum, not an extension, making the separation explicit)
- Renaming files without changing structure (cosmetic changes add churn without benefit)
- Splitting large files into smaller ones (the current sizes are reasonable: 200-400 lines each)

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Subtle behavior changes | Low | High | Targeted changes easier to verify; test coverage audit first (Phase 0) |
| Performance regression | Very Low | Low | No actor hops added; changes are organizational |
| Incomplete improvement | Medium | Low | Phased approach allows stopping at any stable point |
| Progress injection mechanism unclear | Low | Medium | SDK research clarified approach; `metaValues` parameter keeps interface simple |
| Server refactoring deferred too long | Low | Medium | Decision point after Client Phase 3; option to batch Server phases |
| Test coverage gaps hide regressions | Medium | High | Phase 0 as concrete first PR; add tests before refactoring |
| Batch request progress handling | Low | Medium | Both SDKs handle per-request; verify in spike |
| Server handler wrapping complexity | Medium | Medium | Spike Server Phase 3 before full implementation; validator exists, spike focuses on API design |
| `connect()` becomes harder to maintain | Low | Low | Extract if exceeds 100 lines, breaks sequential flow, or requires understanding unrelated steps |
| Elicitation mode validation breaks | Low | Medium | Keep at dispatch time; test coverage in Phase 0 |

---

## Success Metrics

1. No encode-decode-mutate-encode pattern in Client code (centralized in ProtocolLayer via `metaValues` parameter)
2. Request ID used as progress token (matching TypeScript/Python pattern)
3. Handler state (including task-augmented handlers) consolidated into `ClientHandlerRegistry` struct with `inferredCapabilities` computed property
4. Capability merging/validation in testable static helpers (`ClientCapabilityHelpers`, `ServerCapabilityHelpers`)
5. Client request handling has clear section comments documenting flow: validate → route → lookup → context → execute
6. Server `tools/call` handler wrapping at registration time (validated via spike before full implementation)
7. Test coverage improved for refactored areas (Phase 0 as concrete first PR)
8. Code easier to navigate and understand
9. Server refactoring complete (interleaved or batched based on decision point)
10. `Client+Batching.swift` merged into `Client+Requests.swift`
11. `ARCHITECTURE.md` documents key decisions
12. Debug logging added for `inferredCapabilities` to aid troubleshooting

---

## Insights from Other SDKs

### TypeScript SDK Architecture

The TypeScript SDK uses a **three-layer architecture**:

```
McpServer (High-Level API)
    ↓ wraps
Client/Server (Intermediate)
    ↓ extends
Protocol (Base Layer)
```

**Key Implementation Details** (from `/mcp-typescript-sdk/packages/core/src/shared/protocol.ts`):

1. **Request Handling** (`_onrequest()`, lines 677-829, ~150 lines):
   - Handler lookup with fallback: `this._requestHandlers.get(request.method) ?? this.fallbackRequestHandler`
   - Context creation with explicit closures for `sendNotification`, `sendRequest`
   - Promise chain for error handling (`.then()`, `.catch()`)
   - Task-augmented requests detected via `isTaskAugmentedRequestParams()` early in the flow

2. **Progress Token Injection** (`request()`, lines 1084-1240):
   ```typescript
   // Lines 1121-1129
   if (options?.onprogress) {
       this._progressHandlers.set(messageId, options.onprogress);
       jsonrpcRequest.params = {
           ...request.params,
           _meta: { ...request.params?._meta, progressToken: messageId }
       };
   }
   ```

3. **Handler State Organization** (lines 327-339):
   ```typescript
   private _requestHandlers: Map<string, ...> = new Map();
   private _requestHandlerAbortControllers: Map<RequestId, AbortController> = new Map();
   private _notificationHandlers: Map<string, ...> = new Map();
   private _responseHandlers: Map<number, ...> = new Map();
   private _progressHandlers: Map<number, ProgressCallback> = new Map();
   ```
   All handler state co-located in Protocol class—not separated into components.

4. **Handler Wrapping at Registration** (`Server.setRequestHandler()`, lines 225-301):
   ```typescript
   if (method === 'tools/call') {
       const wrappedHandler = async (request, extra) => {
           // Validate request
           // Execute handler
           // Validate result (task or CallToolResult)
       };
       return super.setRequestHandler(requestSchema, wrappedHandler);
   }
   ```

**Why Swift Can't Use the Same Pattern Directly**:

JavaScript's object spread (`{...obj}`) makes runtime property merging trivial. Swift's type system prevents this for generic `M.Parameters` types. Our solution centralizes the decode-mutate-encode in ProtocolLayer, achieving the same logical architecture even if the mechanism differs.

### Python SDK Architecture

The Python SDK uses a **generic session pattern**:

```
Server (High-Level, decorators)
    ↓ uses
ServerSession / ClientSession
    ↓ extends
BaseSession (Generic over request/response types)
```

**Key Implementation Details** (from `/mcp-python-sdk/src/mcp/`):

1. **Request Handling** (`_handle_request()` in `server/lowlevel/server.py`, lines 732-808, ~76 lines):
   - Type-based dispatch: `if handler := self.request_handlers.get(type(req)):`
   - Uses `contextvars.ContextVar` for implicit context propagation
   - Clean try/except with specific exception types

2. **Progress Token Injection** (`send_request()` in `shared/session.py`, lines 252-261):
   ```python
   if progress_callback is not None:
       if "params" not in request_data:
           request_data["params"] = {}
       if "_meta" not in request_data["params"]:
           request_data["params"]["_meta"] = {}
       request_data["params"]["_meta"]["progressToken"] = request_id
       self._progress_callbacks[request_id] = progress_callback
   ```

3. **Decorator-Based Handler Registration** (`server/lowlevel/server.py`, lines 288-656):
   ```python
   def call_tool(self, *, validate_input: bool = True):
       def decorator(func):
           async def handler(req):
               # Input validation
               results = await func(tool_name, arguments)
               # Output normalization and validation
               return types.CallToolResult(...)
           self.request_handlers[types.CallToolRequest] = handler
       return decorator
   ```

4. **Capability Inference** (`get_capabilities()`, lines 209-253):
   ```python
   if types.ListToolsRequest in self.request_handlers:
       tools_capability = types.ToolsCapability(list_changed=...)
   ```

### What We're Adopting

| Pattern | TypeScript | Python | Swift Adaptation |
|---------|------------|--------|------------------|
| Progress token = request ID | ✓ | ✓ | Use request ID, inject in ProtocolLayer |
| Handler wrapping at registration | ✓ | ✓ | Wrap with validation at registration time |
| Single-class organization | ✓ Protocol class | ✓ Session classes | Single actor per role |
| Capability inference | Partial | ✓ | CapabilityHelpers inspect handlers |
| Explicit context passing | ✓ `RequestHandlerExtra` | ✗ (uses contextvars) | `RequestHandlerContext` parameter |

### What We're NOT Adopting

1. **Context Variables**: Python's `contextvars` pattern doesn't translate well to Swift's actor model. Our `RequestHandlerContext` parameter approach is more explicit and type-safe.

2. **Type-Based Dispatch**: Python uses `dict[type, handler]` because Python has runtime type introspection. Swift's string-based method name dispatch is appropriate for our type system.

3. **Memory Streams for Internal Decoupling**: Python uses this to work around async limitations. Swift's structured concurrency with actors handles this more elegantly.

4. **Fallback Handlers**: TypeScript has `fallbackRequestHandler` and `fallbackNotificationHandler`. We don't currently need this extensibility point, but it's a pattern to consider if needed.

---

## Timeline Expectations

This plan intentionally avoids time estimates. The phased approach allows:

- Stopping at any stable point if priorities change
- Evaluating each phase's impact before proceeding
- Adjusting scope based on what we learn

Each phase should be a self-contained improvement that provides value even if subsequent phases are deferred.

---

## Summary

**Critical Path**:

1. **Phase 0**: Concrete first PR adding missing tests (required before any refactoring)
2. **Client Phase 1**: Fix progress token injection (use request ID as token, add `metaValues` parameter to ProtocolLayer)
3. **Client Phase 2**: Consolidate handler state into single `ClientHandlerRegistry` struct with `inferredCapabilities`
4. **Client Phase 3**: Extract capability helpers
5. **Decision Point**: Evaluate whether to interleave or batch Server phases
6. **Server Phase 1**: Apply handler state pattern (spike Server Phase 3 in parallel)
7. **Server Phase 2**: Extract capability helpers
8. **Server Phase 3**: Handler wrapping at registration for `tools/call` validation (if spike validates approach)
9. **Phase 4**: Evaluate, merge `Client+Batching.swift`, create `ARCHITECTURE.md`, add debug logging

**Note**: Client Phase 3.5 (section comments) is zero-risk and can be done at any time, even as part of other PRs.

**Key Patterns Adopted from TypeScript/Python SDKs**:

| Pattern | Source | Swift Adaptation |
|---------|--------|------------------|
| Progress token = request ID | Both | Deterministic mapping, `metaValues` parameter in ProtocolLayer |
| Handler wrapping at registration | TypeScript Server | **Server only**: wrap `tools/call` for input/output schema validation |
| Linear request handling flow | Both | Section comments documenting: validate → route → lookup → context → execute |
| Single-class organization | TypeScript | Single-actor with well-organized methods |
| Capability inference from handlers | Python | `inferredCapabilities` computed property on `ClientHandlerRegistry` |
| Task handler grouping | Python | Task-augmented handlers included in `ClientHandlerRegistry` for unified capability inference |

**Key Clarifications** (from architectural review):

1. **Single struct over two structs**: Handler configuration (`samplingConfig`, etc.) is tightly coupled to handlers. Merging into `ClientHandlerRegistry` with `inferredCapabilities` computed property keeps related data together.

2. **Task-augmented handlers in `ClientHandlerRegistry`**: Following Python SDK's `ExperimentalTaskHandlers.build_capability()` pattern, task-augmented handlers are included in the registry so `inferredCapabilities` can automatically derive tasks capability from handler presence.

3. **Section comments over method extraction**: Both TypeScript (~150 lines) and Python (~76 lines) keep request handling in single methods. Our ~116 lines is comparable. Add section comments for clarity without method indirection.

5. **Client handler validation stays at dispatch time**: Elicitation mode validation requires runtime access to `capabilities.elicitation`. Client handlers don't benefit from registration-time wrapping.

6. **Server handler wrapping requires spike**: TypeScript wraps `tools/call` at registration for schema validation. Swift already has `DefaultJSONSchemaValidator`—the spike focuses on API design for per-tool schema registration, not validation capability.

7. **`connect()` decomposition has concrete trigger**: Extract private helpers if the method exceeds 100 lines, a new step needs insertion into the middle (breaking sequential flow), or adding a responsibility requires understanding unrelated steps.

8. **Extension file reorganization is deferred**: The only clear improvement is merging `Client+Batching.swift` into `Client+Requests.swift` (Phase 4 action item).

9. **Progress token behavior**: The SDK always overwrites any user-provided `progressToken` with the request ID (matching TypeScript/Python behavior). Other `_meta` fields are preserved.

**Key Tradeoffs**:
- Favoring simplicity over abstraction (correct for this codebase size)
- Keeping single-actor design vs. distributed actors (correct choice)
- Single `ClientHandlerRegistry` struct with computed capabilities (keeps related data together)
- Decode-mutate-encode via `metaValues` in ProtocolLayer (unavoidable given Swift's type system)

**Evolution Path**: The architecture can grow by:
- Adding interceptors for cross-cutting concerns (logging, metrics, task augmentation)
- Extracting handler context creation if patterns converge after refactoring
- Adding capability auto-detection for new MCP features by extending helpers
- Decomposing `connect()` if reconnection logic grows more complex
