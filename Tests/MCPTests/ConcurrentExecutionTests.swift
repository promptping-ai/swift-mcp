// Copyright © Anthony DePasquale

import Testing

@testable import MCP

/// Tests that verify server handlers execute concurrently.
///
/// These tests are based on Python SDK's `test_188_concurrency.py`:
/// - `test_messages_are_executed_concurrently_tools`
/// - `test_messages_are_executed_concurrently_tools_and_resources`
///
/// The pattern uses coordination primitives (events) to prove concurrent execution:
/// 1. First handler starts and waits on an event
/// 2. Second handler starts (only possible if handlers run concurrently)
/// 3. Second handler signals the event
/// 4. First handler completes
///
/// If handlers ran sequentially, the first handler would block forever
/// waiting for an event that the second handler (which never starts) should signal.
@Suite("Concurrent Execution Tests")
struct ConcurrentExecutionTests {
    // MARK: - Helper Types

    // MARK: - Concurrent Tool Execution Tests

    /// Tests that tool calls execute concurrently on the server.
    ///
    /// Based on Python SDK's `test_messages_are_executed_concurrently_tools`.
    ///
    /// Pattern:
    /// - "sleep" tool starts and waits on an event
    /// - "trigger" tool starts (proves concurrency), waits for sleep to start, then signals
    /// - Both tools complete
    ///
    /// If execution were sequential, the sleep tool would block forever.
    @Test("Tool calls execute concurrently on server",
          .timeLimit(.minutes(1)))
    func toolCallsExecuteConcurrently() async throws {
        let event = AsyncEvent()
        let toolStarted = AsyncEvent()
        let callOrder = CallOrderTracker()

        let server = Server(
            name: "ConcurrentToolServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "sleep", description: "Waits for event", inputSchema: ["type": "object"]),
                Tool(name: "trigger", description: "Triggers the event", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "sleep" {
                await callOrder.append("waiting_for_event")
                await toolStarted.signal()
                await event.wait()
                await callOrder.append("tool_end")
                return CallTool.Result(content: [.text("done")])
            } else if request.name == "trigger" {
                // Wait for sleep tool to start before signaling
                await toolStarted.wait()
                await callOrder.append("trigger_started")
                await event.signal()
                await callOrder.append("trigger_end")
                return CallTool.Result(content: [.text("triggered")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ConcurrentTestClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Start the sleep tool (will wait on event)
        let sleepTask = Task {
            try await client.send(CallTool.request(.init(name: "sleep", arguments: nil)))
        }

        // Start the trigger tool (will signal the event)
        let triggerTask = Task {
            try await client.send(CallTool.request(.init(name: "trigger", arguments: nil)))
        }

        // Wait for both to complete
        _ = try await sleepTask.value
        _ = try await triggerTask.value

        // Verify the order proves concurrent execution
        let events = await callOrder.events
        #expect(
            events == ["waiting_for_event", "trigger_started", "trigger_end", "tool_end"],
            "Expected concurrent execution order, but got: \(events)"
        )
    }

    /// Tests that tool and resource handlers execute concurrently.
    ///
    /// Based on Python SDK's `test_messages_are_executed_concurrently_tools_and_resources`.
    ///
    /// Pattern:
    /// - "sleep" tool starts and waits on an event
    /// - resource read starts (proves concurrency), signals the event
    /// - Both complete
    @Test("Tool and resource calls execute concurrently on server",
          .timeLimit(.minutes(1)))
    func toolAndResourceCallsExecuteConcurrently() async throws {
        let event = AsyncEvent()
        let toolStarted = AsyncEvent()
        let callOrder = CallOrderTracker()

        let server = Server(
            name: "ConcurrentMixedServer",
            version: "1.0.0",
            capabilities: .init(resources: .init(), tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "sleep", description: "Waits for event", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "sleep" {
                await callOrder.append("waiting_for_event")
                await toolStarted.signal()
                await event.wait()
                await callOrder.append("tool_end")
                return CallTool.Result(content: [.text("done")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(name: "Slow Resource", uri: "test://slow_resource"),
            ])
        }

        await server.withRequestHandler(ReadResource.self) { request, _ in
            if request.uri == "test://slow_resource" {
                // Wait for tool to start before signaling
                await toolStarted.wait()
                await event.signal()
                await callOrder.append("resource_end")
                return ReadResource.Result(contents: [
                    .text("slow", uri: "test://slow_resource"),
                ])
            }
            return ReadResource.Result(contents: [])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ConcurrentMixedClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Start the sleep tool (will wait on event)
        let sleepTask = Task {
            try await client.send(CallTool.request(.init(name: "sleep", arguments: nil)))
        }

        // Start the resource read (will signal the event)
        let resourceTask = Task {
            try await client.send(ReadResource.request(.init(uri: "test://slow_resource")))
        }

        // Wait for both to complete
        _ = try await sleepTask.value
        _ = try await resourceTask.value

        // Verify the order proves concurrent execution
        let events = await callOrder.events
        #expect(
            events == ["waiting_for_event", "resource_end", "tool_end"],
            "Expected concurrent execution order, but got: \(events)"
        )
    }

    /// Tests that multiple concurrent tool calls all execute in parallel.
    ///
    /// Pattern: Start N tools that all wait on a shared event, then signal it once.
    /// If sequential, only the first would run and block forever.
    @Test("Multiple concurrent tool calls all execute in parallel",
          .timeLimit(.minutes(1)))
    func multipleConcurrentToolCallsExecuteInParallel() async throws {
        let event = AsyncEvent()
        let startedCount = CallCounter()
        let expectedConcurrency = 5

        let server = Server(
            name: "ParallelToolServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "wait_tool", description: "Waits for event", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, _ in
            // Track that this handler started
            await startedCount.increment()

            // Wait for the event
            await event.wait()
            return CallTool.Result(content: [.text("done")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ParallelTestClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Start multiple tool calls concurrently
        let tasks = (0 ..< expectedConcurrency).map { _ in
            Task {
                try await client.send(CallTool.request(.init(name: "wait_tool", arguments: nil)))
            }
        }

        // Wait for all handlers to start (proves they're running concurrently)
        var attempts = 0
        while await startedCount.value < expectedConcurrency, attempts < 100 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }

        let started = await startedCount.value
        #expect(
            started == expectedConcurrency,
            "All \(expectedConcurrency) handlers should have started concurrently, but only \(started) started"
        )

        // Signal the event to let all handlers complete
        await event.signal()

        // Wait for all tasks to complete
        for task in tasks {
            _ = try await task.value
        }
    }

    /// Tests that a tool throwing an error does not affect other concurrent tool calls.
    ///
    /// Pattern:
    /// - Start a "failing" tool and a "succeeding" tool concurrently
    /// - The failing tool throws after the succeeding tool starts (proving concurrency)
    /// - The succeeding tool completes normally despite the other tool's failure
    @Test("Concurrent tool error does not affect other tool calls",
          .timeLimit(.minutes(1)))
    func concurrentToolErrorDoesNotAffectOthers() async throws {
        let succeedingToolStarted = AsyncEvent()
        let succeedingToolCanFinish = AsyncEvent()

        let server = Server(
            name: "ErrorIsolationServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "failing", description: "Will throw", inputSchema: ["type": "object"]),
                Tool(name: "succeeding", description: "Will succeed", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "failing" {
                // Wait for the succeeding tool to start (proves concurrency)
                await succeedingToolStarted.wait()
                // Throw an error
                throw MCPError.internalError("Deliberate failure")
            } else if request.name == "succeeding" {
                await succeedingToolStarted.signal()
                // Wait for permission to finish (after the failing tool has thrown)
                await succeedingToolCanFinish.wait()
                return CallTool.Result(content: [.text("success")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ErrorIsolationClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Start both tool calls concurrently
        let failingTask = Task {
            try await client.send(CallTool.request(.init(name: "failing", arguments: nil)))
        }

        let succeedingTask = Task {
            try await client.send(CallTool.request(.init(name: "succeeding", arguments: nil)))
        }

        // The failing tool's error is returned as a JSON-RPC error response,
        // which causes client.send() to throw.
        do {
            _ = try await failingTask.value
            Issue.record("Failing tool should throw an error")
        } catch {
            // Expected - the error propagates from the server handler
        }

        // Now let the succeeding tool finish
        await succeedingToolCanFinish.signal()

        let succeedResult = try await succeedingTask.value
        #expect(
            succeedResult.content.first != nil,
            "Succeeding tool should complete normally despite concurrent failure"
        )
        if case let .text(text, _, _) = succeedResult.content.first {
            #expect(text == "success")
        }
    }

    /// Tests that cancelling one tool call does not affect other concurrent tool calls.
    ///
    /// Pattern:
    /// - Start two tools concurrently, both block on events
    /// - Cancel the first tool call's task
    /// - Signal the second tool to finish
    /// - Verify the second tool completes normally
    @Test("Cancelling one tool call does not affect others",
          .timeLimit(.minutes(1)))
    func cancellingOneToolCallDoesNotAffectOthers() async throws {
        let toolAStarted = AsyncEvent()
        let toolBStarted = AsyncEvent()
        let toolBCanFinish = AsyncEvent()

        let server = Server(
            name: "CancellationIsolationServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "tool_a", description: "Will be cancelled", inputSchema: ["type": "object"]),
                Tool(name: "tool_b", description: "Should succeed", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "tool_a" {
                await toolAStarted.signal()
                // Block forever (will be cancelled)
                try await Task.sleep(for: .seconds(300))
                return CallTool.Result(content: [.text("a_done")])
            } else if request.name == "tool_b" {
                await toolBStarted.signal()
                await toolBCanFinish.wait()
                return CallTool.Result(content: [.text("b_done")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "CancellationClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Start both tool calls
        let taskA = Task {
            try await client.send(CallTool.request(.init(name: "tool_a", arguments: nil)))
        }

        let taskB = Task {
            try await client.send(CallTool.request(.init(name: "tool_b", arguments: nil)))
        }

        // Wait for both handlers to start
        await toolAStarted.wait()
        await toolBStarted.wait()

        // Cancel task A
        taskA.cancel()

        // Let task B finish
        await toolBCanFinish.signal()

        let resultB = try await taskB.value
        if case let .text(text, _, _) = resultB.content.first {
            #expect(text == "b_done", "Tool B should complete normally after Tool A is cancelled")
        } else {
            Issue.record("Expected text content from tool B")
        }
    }
}
