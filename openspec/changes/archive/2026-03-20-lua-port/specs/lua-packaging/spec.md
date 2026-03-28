## ADDED Requirements

### Requirement: Build script produces a single-file adapter artifact
`build/amalg.lua` SHALL invoke `lua-amalg` to bundle `src/lua/entry.lua` and all its transitive `require()` dependencies into `dist/adapter.lua`. The output file SHALL expose the global `adapter_call(request_json)` function.

#### Scenario: dist/adapter.lua is produced by build script
- **WHEN** the build script is executed
- **THEN** `dist/adapter.lua` is created (or overwritten) containing all module code
- **AND** the file defines `adapter_call` as a global function

#### Scenario: dist/adapter.lua has no unresolved require calls
- **WHEN** `dist/adapter.lua` is installed as a Lua Adapter Script in Exasol
- **THEN** no `require()` call fails at runtime due to a missing module
- **AND** the adapter responds correctly to `createVirtualSchema` requests

### Requirement: dist/adapter.lua is the only file needed for deployment
An operator SHALL be able to deploy the adapter by pasting `dist/adapter.lua` into a single `CREATE OR REPLACE LUA ADAPTER SCRIPT` statement. No BucketFS upload, JAR build, or additional files SHALL be required.

#### Scenario: One-statement install
- **WHEN** an operator executes `CREATE OR REPLACE LUA ADAPTER SCRIPT ADAPTER.VECTOR_SCHEMA_ADAPTER AS <contents of dist/adapter.lua> /`
- **THEN** the adapter is installed and functional
- **AND** no other installation steps are required
