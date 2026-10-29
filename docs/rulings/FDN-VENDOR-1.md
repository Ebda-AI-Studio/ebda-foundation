# FDN-VENDOR-1

Ruling FDN-VENDOR-1 - consumers import the vendored foundation by relative path, not through an npm workspace or a `file:` dependency. The Store's `@ebda/shared` compiles with `rootDir: src`, which refuses source files outside it (TS6059), and a workspace or `file:` link needs a lockfile edit plus a node_modules symlink in every worktree. The lock's `dir` field records where each consumer put the copy (Store: `packages/shared/src/foundation`, WhatsApp: `foundation`). Cost if wrong: switching a consumer to a workspace is a lock `dir` change plus an import-path rewrite.
