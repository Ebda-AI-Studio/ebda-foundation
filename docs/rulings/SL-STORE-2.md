# SL-STORE-2

Ruling SL-STORE-2 - Store tools run through `runAsMerchant` (extracted from `apps/api/src/mcp/merchant-write.ts`: RBAC `hasPermission`, `requireFeature` key, audit intent row fail-closed, tenant context), the same path the Merchant MCP write tools use. Cost if wrong: two auth paths drift; mitigated because MCP and assistant share the extracted function.
