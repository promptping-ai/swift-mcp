# Resources

Register resources that clients can read and subscribe to

## Overview

Resources represent data that your server exposes to clients. Each resource has a URI and content. Clients can list resources, read their contents, and optionally subscribe to updates.

## Registering Resources

Register handlers for listing and reading resources:

```swift
// List available resources
await server.withRequestHandler(ListResources.self) { _, _ in
    ListResources.Result(resources: [
        Resource(
            name: "Configuration",
            uri: "config://app",
            description: "Application configuration",
            mimeType: "application/json"
        ),
        Resource(
            name: "Logs",
            uri: "logs://app/recent",
            description: "Recent application logs"
        )
    ])
}

// Read resource content
await server.withRequestHandler(ReadResource.self) { params, _ in
    switch params.uri {
    case "config://app":
        let config = loadConfiguration()
        return ReadResource.Result(contents: [
            .text(config.jsonString, uri: params.uri, mimeType: "application/json")
        ])

    default:
        throw MCPError.resourceNotFound(uri: params.uri)
    }
}
```

## Resource Content Types

### Text Content

```swift
ReadResource.Result(contents: [
    .text(
        "file contents here",
        uri: "file:///path/to/file.txt",
        mimeType: "text/plain"
    )
])
```

### Binary Content

For binary data, use base64 encoding:

```swift
let imageData: Data = // binary data
ReadResource.Result(contents: [
    .binary(
        imageData,
        uri: "image:///chart.png",
        mimeType: "image/png"
    )
])
```

### Multiple Contents

A single resource can return multiple content items:

```swift
ReadResource.Result(contents: [
    .text(summary, uri: params.uri, mimeType: "text/plain"),
    .text(details, uri: "\(params.uri)/details", mimeType: "application/json")
])
```

## Resource Metadata

Resources support optional metadata:

```swift
Resource(
    name: "report.pdf",
    uri: "file:///docs/report.pdf",
    description: "Monthly report",
    mimeType: "application/pdf",
    size: 1048576,  // Size in bytes (1 MB)
    icons: [
        Icon(src: "https://example.com/pdf-icon.png", mimeType: "image/png")
    ]
)
```

The `size` field helps clients display file sizes or make decisions about downloading large resources.

## Resource Annotations

Resources and content blocks support optional annotations that help clients understand how to use them:

- **audience**: Who should see this resource (`["user"]`, `["assistant"]`, or `["user", "assistant"]`)
- **priority**: Importance from 0.0 (optional) to 1.0 (required)
- **lastModified**: ISO 8601 timestamp of last modification

```swift
Resource(
    name: "README",
    uri: "file:///project/README.md",
    mimeType: "text/markdown",
    annotations: .init(
        audience: [.user],
        priority: 0.8,
        lastModified: "2025-01-09T12:00:00Z"
    )
)
```

Clients can use annotations to filter resources, prioritize context inclusion, or display modification times.

## Resource Templates

Expose dynamic resources with URI templates:

```swift
await server.withRequestHandler(ListResourceTemplates.self) { _, _ in
    ListResourceTemplates.Result(templates: [
        Resource.Template(
            uriTemplate: "file:///{path}",
            name: "File",
            description: "Access files by path"
        ),
        Resource.Template(
            uriTemplate: "user://{userId}/profile",
            name: "User Profile",
            description: "User profile data"
        )
    ])
}
```

Clients substitute template variables to construct URIs for `ReadResource`.

## Resource Subscriptions

If you declared `resources.subscribe` capability, handle subscription requests:

```swift
var subscriptions: Set<String> = []

await server.withRequestHandler(ResourceSubscribe.self) { params, _ in
    subscriptions.insert(params.uri)
    return ResourceSubscribe.Result()
}

await server.withRequestHandler(ResourceUnsubscribe.self) { params, _ in
    subscriptions.remove(params.uri)
    return ResourceUnsubscribe.Result()
}
```

### Notifying Subscribers

When a resource changes, notify subscribed clients:

```swift
// Resource content changed
try await context.sendResourceUpdated(uri: "config://app")
```

### Notifying List Changes

If you declared `resources.listChanged` capability, notify when resources are added or removed:

```swift
// Resource list changed
try await context.sendResourceListChanged()
```

## Complete Example

```swift
let server = Server(
    name: "FileServer",
    version: "1.0.0",
    capabilities: Server.Capabilities(
        resources: .init(subscribe: true, listChanged: true)
    )
)

var watchedFiles: Set<String> = []

await server.withRequestHandler(ListResources.self) { _, _ in
    let files = listDirectory("/data")
    return ListResources.Result(resources: files.map { file in
        Resource(
            name: file.name,
            uri: "file:///data/\(file.name)",
            mimeType: file.mimeType
        )
    })
}

await server.withRequestHandler(ReadResource.self) { params, _ in
    guard params.uri.hasPrefix("file:///data/") else {
        throw MCPError.resourceNotFound(uri: params.uri)
    }
    let path = String(params.uri.dropFirst("file://".count))
    let content = try readFile(path)
    return ReadResource.Result(contents: [
        .text(content, uri: params.uri)
    ])
}

await server.withRequestHandler(ResourceSubscribe.self) { params, _ in
    watchedFiles.insert(params.uri)
    return ResourceSubscribe.Result()
}
```

## See Also

- <doc:server-setup>
- <doc:client-resources>
- ``Server``
- ``Resource``
