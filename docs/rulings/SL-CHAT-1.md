# SL-CHAT-1

Ruling SL-CHAT-1 - Chat journal in the `WorkspaceDO` SQLite (new `do-migrations.ts` entries). Chat tools execute as an in-process sub-request to Chat's own Hono `api` with the merchant's original auth headers, so every action passes the exact route authorization. Cost if wrong: one extra in-process dispatch per tool call.
