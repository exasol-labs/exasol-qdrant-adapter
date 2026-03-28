## ADDED Requirements

### Requirement: AdapterProperties defines and validates required properties
`AdapterProperties` SHALL expose constants for all property keys (`CONNECTION_NAME`, `QDRANT_MODEL`, `OLLAMA_URL`, `QDRANT_URL`) and SHALL raise an explicit, actionable error if any required property is absent.

#### Scenario: Missing CONNECTION_NAME raises error
- **WHEN** `create_virtual_schema` or `push_down` is called without `CONNECTION_NAME` set
- **THEN** the adapter raises an error message that names the missing property
- **AND** no HTTP call is made

#### Scenario: Missing QDRANT_MODEL raises error
- **WHEN** `push_down` is called without `QDRANT_MODEL` set
- **THEN** the adapter raises an error message that names the missing property

#### Scenario: Optional properties use defaults when absent
- **WHEN** `OLLAMA_URL` is not set
- **THEN** the adapter uses `http://localhost:11434` as the Ollama base URL
- **WHEN** `QDRANT_URL` is not set
- **THEN** the adapter derives the Qdrant URL from the `CONNECTION` object address

### Requirement: AdapterProperties supports merge semantics for setProperties
When `set_properties` is called, `AdapterProperties` SHALL merge existing properties with new ones. A property explicitly set to an empty string SHALL be treated as unset (removed).

#### Scenario: New value overrides old value
- **WHEN** `set_properties` is called with `QDRANT_MODEL = 'new-model'`
- **THEN** subsequent calls use `new-model` as the model name

#### Scenario: Empty string unsets a property
- **WHEN** `set_properties` is called with `OLLAMA_URL = ''`
- **THEN** `OLLAMA_URL` reverts to its default value on the next call
