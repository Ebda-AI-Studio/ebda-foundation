# FDN-DIST-1

Ruling FDN-DIST-1 - the foundation is a source-of-truth repo (`Ebda-AI-Studio/ebda-foundation`) distributed as sha-pinned vendored copies written by its own CLI (`sync`) and checked by a lock-file drift test. A git-tag dependency needs a credential in every workflow, GitHub Packages has quota and token failure modes on a free plan, a template repo loses its link; a vendored copy needs zero network and zero auth. Cost if wrong: about one extra PR per bump per product; moving to a registry later is mechanical because package name and import paths do not change.
