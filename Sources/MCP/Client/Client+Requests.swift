// Copyright © Anthony DePasquale

import Foundation

public extension Client {
    // MARK: - Request Options

    /// Options that can be given per request.
    ///
    /// Similar to TypeScript SDK's `RequestOptions`, this allows configuring
    /// timeout behavior for individual requests, including progress-aware timeouts.
    struct RequestOptions: Sendable {
        /// The default request timeout (60 seconds), matching TypeScript SDK.
        public static let defaultTimeout: Duration = .seconds(60)

        /// A timeout for this request.
        ///
        /// If exceeded, the request will be cancelled and an `MCPError.requestTimeout`
        /// will be thrown. A `CancelledNotification` will also be sent to the server.
        ///
        /// If `nil`, no timeout is applied (the request can wait indefinitely).
        /// Default is `nil` to match existing behavior.
        public var timeout: Duration?

        /// If `true`, receiving a progress notification resets the timeout clock.
        ///
        /// This is useful for long-running operations that send periodic progress updates.
        /// As long as the server keeps sending progress, the request won't time out.
        ///
        /// When combined with `maxTotalTimeout`, this allows both:
        /// - Per-interval timeout that resets on progress
        /// - Overall hard limit that prevents infinite waiting
        ///
        /// Default is `false`.
        ///
        /// - Note: Only effective when `timeout` is set and the request uses `onProgress`.
        public var resetTimeoutOnProgress: Bool

        /// Maximum total time to wait for the request, regardless of progress.
        ///
        /// When `resetTimeoutOnProgress` is `true`, this provides a hard upper limit
        /// on the total wait time. Even if progress notifications keep arriving,
        /// the request will be cancelled if this limit is exceeded.
        ///
        /// If `nil`, there's no maximum total timeout (only the regular `timeout`
        /// applies, potentially reset by progress).
        ///
        /// - Note: Only effective when both `timeout` and `resetTimeoutOnProgress` are set.
        public var maxTotalTimeout: Duration?

        /// Creates request options with the specified configuration.
        ///
        /// - Parameters:
        ///   - timeout: The timeout duration, or `nil` for no timeout.
        ///   - resetTimeoutOnProgress: Whether to reset the timeout when progress is received.
        ///   - maxTotalTimeout: Maximum total time to wait regardless of progress.
        public init(
            timeout: Duration? = nil,
            resetTimeoutOnProgress: Bool = false,
            maxTotalTimeout: Duration? = nil
        ) {
            self.timeout = timeout
            self.resetTimeoutOnProgress = resetTimeoutOnProgress
            self.maxTotalTimeout = maxTotalTimeout
        }

        /// Request options with the default timeout (60 seconds).
        public static let withDefaultTimeout = RequestOptions(timeout: defaultTimeout)

        /// Request options with no timeout.
        public static let noTimeout = RequestOptions(timeout: nil)
    }

    // MARK: - Requests

    /// Send a request and receive its response.
    ///
    /// This method sends a request without a timeout. For timeout support,
    /// use `send(_:options:)` instead.
    func send<M: Method>(_ request: Request<M>) async throws -> M.Result {
        try await send(request, options: nil)
    }

    /// Send a request and receive its response with options.
    ///
    /// Delegates to the protocol conformance for request tracking, timeout, and response matching.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - options: Options for this request, including timeout configuration.
    /// - Returns: The response result.
    /// - Throws: `MCPError.requestTimeout` if the timeout is exceeded.
    func send<M: Method>(
        _ request: Request<M>,
        options: RequestOptions?
    ) async throws -> M.Result {
        guard isProtocolConnected else {
            throw MCPError.internalError("Client connection not initialized")
        }

        let requestData = try encoder.encode(request)
        let requestId = request.id

        do {
            let protocolOptions = ProtocolRequestOptions(
                timeout: options?.timeout,
                resetTimeoutOnProgress: options?.resetTimeoutOnProgress ?? false,
                maxTotalTimeout: options?.maxTotalTimeout
            )

            let responseData = try await sendProtocolRequest(
                requestData,
                requestId: requestId,
                options: protocolOptions
            )

            return try decoder.decode(M.Result.self, from: responseData)
        } catch {
            // Send CancelledNotification for timeouts and task cancellations per MCP spec.
            // Check Task.isCancelled as well since the error may propagate as
            // MCPError.connectionClosed when the stream ends due to cancellation.
            if error is CancellationError || Task.isCancelled {
                await sendCancellationNotification(
                    requestId: requestId,
                    reason: "Client cancelled the request"
                )
            } else if case let .requestTimeout(t, _) = error as? MCPError {
                await sendCancellationNotification(
                    requestId: requestId,
                    reason: "Request timed out after \(t)"
                )
            }
            throw error
        }
    }

    /// Send a request with a progress callback.
    ///
    /// This method automatically sets up progress tracking by:
    /// 1. Generating a unique progress token based on the request ID
    /// 2. Injecting the token into the request's `_meta.progressToken`
    /// 3. Invoking the callback when progress notifications are received
    ///
    /// The callback is automatically cleaned up when the request completes.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = try await client.send(
    ///     CallTool.request(.init(name: "slow_operation", arguments: ["steps": 5])),
    ///     onProgress: { progress in
    ///         print("Progress: \(progress.value)/\(progress.total ?? 0) - \(progress.message ?? "")")
    ///     }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - request: The request to send
    ///   - onProgress: A callback invoked when progress notifications are received
    /// - Returns: The response result
    func send<M: Method>(
        _ request: Request<M>,
        onProgress: @escaping ProgressCallback
    ) async throws -> M.Result {
        try await send(request, options: nil, onProgress: onProgress)
    }

    /// Send a request with options and a progress callback.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - options: Options for this request, including timeout configuration.
    ///   - onProgress: A callback invoked when progress notifications are received.
    /// - Returns: The response result.
    /// - Throws: `MCPError.requestTimeout` if the timeout is exceeded.
    func send<M: Method>(
        _ request: Request<M>,
        options: RequestOptions?,
        onProgress: @escaping ProgressCallback
    ) async throws -> M.Result {
        guard isProtocolConnected else {
            throw MCPError.internalError("Client connection not initialized")
        }

        // Generate a progress token from the request ID
        let progressToken: ProgressToken = switch request.id {
            case let .number(n): .integer(n)
            case let .string(s): .string(s)
        }

        // Encode the request, inject progressToken into _meta, then re-encode
        let requestData = try encoder.encode(request)
        var requestDict = try decoder.decode([String: Value].self, from: requestData)

        // Ensure params exists and inject _meta.progressToken
        var params = requestDict["params"]?.objectValue ?? [:]
        var meta = params["_meta"]?.objectValue ?? [:]
        meta["progressToken"] = switch progressToken {
            case let .string(s): .string(s)
            case let .integer(n): .int(n)
        }
        params["_meta"] = .object(meta)
        requestDict["params"] = .object(params)

        let modifiedRequestData = try encoder.encode(requestDict)
        let requestId = request.id

        // Build protocol options with progress tracking
        let protocolOptions = ProtocolRequestOptions(
            progressToken: progressToken,
            onProgress: { params in
                let progress = Progress(
                    value: params.progress,
                    total: params.total,
                    message: params.message
                )
                await onProgress(progress)
            },
            timeout: options?.timeout,
            resetTimeoutOnProgress: options?.resetTimeoutOnProgress ?? false,
            maxTotalTimeout: options?.maxTotalTimeout
        )

        do {
            let responseData = try await sendProtocolRequest(
                modifiedRequestData,
                requestId: requestId,
                options: protocolOptions
            )

            return try decoder.decode(M.Result.self, from: responseData)
        } catch {
            // Send CancelledNotification for timeouts and task cancellations per MCP spec.
            // Check Task.isCancelled as well since the error may propagate as
            // MCPError.connectionClosed when the stream ends due to cancellation.
            if error is CancellationError || Task.isCancelled {
                await sendCancellationNotification(
                    requestId: requestId,
                    reason: "Client cancelled the request"
                )
            } else if case let .requestTimeout(t, _) = error as? MCPError {
                await sendCancellationNotification(
                    requestId: requestId,
                    reason: "Request timed out after \(t)"
                )
            }
            throw error
        }
    }

    // MARK: - Request Cancellation

    /// Cancel an in-flight request by its ID.
    ///
    /// This method cancels a pending request and sends a `CancelledNotification` to the server.
    /// Use this when you need to cancel a request that was sent earlier but hasn't completed yet.
    ///
    /// Per MCP spec: "When a party wants to cancel an in-progress request, it sends a
    /// `notifications/cancelled` notification containing the ID of the request to cancel."
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create a request with a known ID
    /// let requestId = RequestId.string("my-request-123")
    /// let request = CallTool.request(id: requestId, .init(name: "slow_operation"))
    ///
    /// // Start the request in a separate task
    /// Task {
    ///     do {
    ///         let result = try await client.send(request)
    ///         print("Result: \(result)")
    ///     } catch let error as MCPError where error.code == MCPError.Code.requestCancelled {
    ///         print("Request was cancelled")
    ///     }
    /// }
    ///
    /// // Later, cancel it by ID
    /// try await client.cancelRequest(requestId, reason: "User cancelled")
    /// ```
    ///
    /// - Parameters:
    ///   - id: The ID of the request to cancel. This must match the ID used when sending the request.
    ///   - reason: An optional human-readable reason for the cancellation, for logging/debugging.
    /// - Throws: This method does not throw. Cancellation notifications are best-effort per the spec.
    ///
    /// - Note: If the request has already completed or is unknown, this is a no-op per the MCP spec.
    /// - Note: The `initialize` request MUST NOT be cancelled per the MCP spec.
    /// - Important: For task-augmented requests, use the `tasks/cancel` method instead.
    func cancelRequest(_ id: RequestId, reason: String? = nil) async {
        // Cancel pending request and clean up progress/timeout state
        cancelProtocolPendingRequest(
            id: id,
            error: MCPError.requestCancelled(reason: reason)
        )
        cleanUpRequestProgress(requestId: id)

        // Send cancellation notification to server (best-effort)
        await sendCancellationNotification(requestId: id, reason: reason)
    }

    /// Send a CancelledNotification to the server for a cancelled request.
    ///
    /// Per MCP spec: "When a party wants to cancel an in-progress request, it sends
    /// a `notifications/cancelled` notification containing the ID of the request to cancel."
    ///
    /// This is called when a client Task waiting for a response is cancelled.
    /// The notification is sent on a best-effort basis - failures are logged but not thrown.
    internal func sendCancellationNotification(requestId: RequestId, reason: String?) async {
        guard let transport = protocolState.transport else {
            logger?.debug(
                "Cannot send cancellation notification - not connected",
                metadata: ["requestId": "\(requestId)"]
            )
            return
        }

        let notification = CancelledNotification.message(.init(
            requestId: requestId,
            reason: reason
        ))

        do {
            let notificationData = try encoder.encode(notification)
            try await transport.send(notificationData)
            logger?.debug(
                "Sent cancellation notification",
                metadata: [
                    "requestId": "\(requestId)",
                    "reason": "\(reason ?? "none")",
                ]
            )
        } catch {
            // Log but don't throw - cancellation notification is best-effort
            // per MCP spec's fire-and-forget nature of notifications
            logger?.debug(
                "Failed to send cancellation notification",
                metadata: [
                    "requestId": "\(requestId)",
                    "error": "\(error)",
                ]
            )
        }
    }
}
