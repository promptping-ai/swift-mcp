# ``MCP``

Swift SDK for the Model Context Protocol

## Overview

The Model Context Protocol defines a standardized way for applications to communicate with AI models. This Swift SDK offers the latest features from the [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/) version of the MCP specification.

- **Build MCP clients** that connect to servers and access tools, resources, and prompts
- **Build MCP servers** that expose capabilities to AI applications
- **Connect over** stdio, HTTP, in-memory, or TCP/UDP

## Topics

### Guides

- <doc:GettingStarted>
- <doc:ClientGuide>
- <doc:ServerGuide>
- <doc:Transports>
- <doc:Debugging>
- <doc:Experimental>

### Core

- ``Client``
- ``Server``

### Transport Types

- ``Transport``
- ``StdioTransport``
- ``HTTPClientTransport``
- ``HTTPServerTransport``
- ``InMemoryTransport``
- ``NetworkTransport``
