## ADDED Requirements

### Requirement: Lua entrypoint exposes global adapter_call function
The adapter SHALL define a global `adapter_call(request_json)` function in `entry.lua` that delegates all request handling to `RequestDispatcher` from `virtual-schema-common-lua`. The entrypoint SHALL NOT contain business logic.

#### Scenario: Adapter call is dispatched correctly
- **WHEN** Exasol invokes `adapter_call` with a JSON request string
- **THEN** the dispatcher routes the request to the correct handler method on `QdrantAdapter`
- **AND** the handler's return value is returned as the response JSON string

### Requirement: Adapter implements the full Virtual Schema lifecycle
`QdrantAdapter` SHALL inherit from `AbstractVirtualSchemaAdapter` and implement `create_virtual_schema`, `refresh`, `push_down`, and `set_properties`. Each method SHALL validate properties before proceeding.

#### Scenario: createVirtualSchema returns schema metadata
- **WHEN** Exasol sends a `createVirtualSchema` request
- **THEN** the adapter reads Qdrant collections via MetadataReader and returns table metadata for each collection

#### Scenario: refresh re-reads metadata
- **WHEN** Exasol sends a `refresh` request
- **THEN** the adapter re-calls MetadataReader and returns updated table metadata

#### Scenario: setProperties merges and validates
- **WHEN** Exasol sends a `setProperties` request with new property values
- **THEN** the adapter merges old and new properties, validates the result, re-reads metadata, and returns updated schema metadata

#### Scenario: pushDown delegates to QueryRewriter
- **WHEN** Exasol sends a `pushDown` request
- **THEN** the adapter delegates to QueryRewriter and returns the rewritten SQL string

### Requirement: Adapter is stateless per call
The adapter SHALL NOT store state in Lua globals between calls. All configuration SHALL come from the request payload and adapter properties.

#### Scenario: Concurrent calls are independent
- **WHEN** two `adapter_call` invocations occur with different property values
- **THEN** each invocation uses only the properties from its own request
- **AND** neither invocation's state is visible to the other

### Requirement: Logging uses remotelog, never print
All log output SHALL use the `remotelog` library provided by `virtual-schema-common-lua`. Direct calls to `print()` SHALL NOT appear in any adapter module.

#### Scenario: Debug log is emitted via remotelog
- **WHEN** `LOG_LEVEL` is set to `DEBUG` in adapter properties
- **THEN** debug-level messages are forwarded to the configured `DEBUG_ADDRESS`
- **AND** no output is written via `print()`
