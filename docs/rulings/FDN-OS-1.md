# FDN-OS-1

Ruling FDN-OS-1 - ebda-foundation is one repository with two layers: `os/` (the AI OS that serves every business) and `packages/` (the product library every Ebda product vendors). The OS source is the predecessor repository at tag `final-before-ebda`, ported in; launchd labels use the prefix `com.ebda.os`. Evidence: Ahmad, 2026-11-05 (Ebda is now the main company and the foundation serves every business); the product library already lives here (v0.1.0). Cost if wrong: splitting the layers later is a `git filter-repo` of `os/` into its own repository.
