# Getting Started

Get up and running with the MCP Swift SDK.

## In-Process Connection

The simplest way to get started is connecting a client and server within the same process using ``InMemoryTransport``. This is ideal for testing, learning, and embedded scenarios.

```swift
import MCP

// Create the server
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(tools: .init())
)

// Handle requests to list tools
await server.withRequestHandler(ListTools.self) { _, _ in
    return .init(tools: [
        Tool(
            name: "greet",
            description: "Greet someone by name",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Name to greet"]
                ],
                "required": ["name"]
            ]
        )
    ])
}

// Handle requests to call tools
await server.withRequestHandler(CallTool.self) { params, _ in
    guard params.name == "greet" else {
        return .init(content: [.text("Unknown tool")], isError: true)
    }
    let name = params.arguments?["name"]?.stringValue ?? "World"
    return .init(content: [.text("Hello, \(name)!")])
}

// Create the client
let client = Client(name: "MyApp", version: "1.0.0")

// Create a connected transport pair
let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

// Start the server and connect the client
try await server.start(transport: serverTransport)
try await client.connect(transport: clientTransport)

// Use the client to interact with the server
let tools = try await client.listTools()
print("Available tools: \(tools.tools.map { $0.name })")

let result = try await client.callTool(name: "greet", arguments: ["name": "MCP"])
if case .text(let text, _, _) = result.content.first {
    print(text)  // "Hello, MCP!"
}

// Clean up
await client.disconnect()
await server.stop()
```

## stdio

```swift
import MCP

@main
struct MyMCPServer {
    static func main() async throws {
        // Create a server
        let server = Server(
            name: "MyServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        // Handle requests to list tools
        await server.withRequestHandler(ListTools.self) { _, _ in
            return .init(tools: [
                Tool(
                    name: "echo",
                    description: "Echo a message",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "message": ["type": "string"]
                        ],
                        "required": ["message"]
                    ]
                )
            ])
        }

        // Handle requests to call tools
        await server.withRequestHandler(CallTool.self) { params, _ in
            guard params.name == "echo" else {
                return .init(content: [.text("Unknown tool")], isError: true)
            }
            let message = params.arguments?["message"]?.stringValue ?? ""
            return .init(content: [.text(message)])
        }

        // Start the server using stdio transport (reads from stdin, writes to stdout)
        let transport = StdioTransport()
        try await server.start(transport: transport)

        // Block until the server is stopped or the process is terminated
        try await server.waitUntilCompleted()
    }
}
```

To build a client that spawns a stdio server, see the <doc:ClientGuide>.

## HTTP

HTTP transport enables communication over the network—locally, on a LAN, or remotely.

```swift
import MCP

let client = Client(name: "MyApp", version: "1.0.0")

let transport = HTTPClientTransport(
    endpoint: URL(string: "https://api.example.com/mcp")!
)

try await client.connect(transport: transport)

// Use the client
let tools = try await client.listTools()
let result = try await client.callTool(name: "ping", arguments: [:])
```

For building HTTP servers, see the [integration examples](https://github.com/DePasqualeOrg/mcp-swift-sdk/tree/main/Examples) with Hummingbird and Vapor.

## Next Steps

- <doc:ClientGuide>: Complete guide to building MCP clients
- <doc:ServerGuide>: Complete guide to building MCP servers
- <doc:Transports>: Available transport options
