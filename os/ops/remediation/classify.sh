# shellcheck shell=bash
# classify <finding-class> -> CLASS_A | CLASS_B | EXCLUDED
#
# EXCLUDED = human-only (draft PR + Telegram, NEVER auto-merge): money, auth,
# RLS, security, migrations, secrets, env/deploy config. Matched with SUBSTRING
# globs, not exact strings — the live detectors emit compound class labels like
# `security-rls`, `security-injection`, `security-validation`, `rls-policy`,
# which exact-string matching let fall through to the autonomous CLASS_B
# auto-merge path (contradicting the design's hard human-only constraint).
# Over-inclusion here is fail-SAFE: the worst case is an extra human review,
# never an unreviewed auto-merge of a sensitive change.
classify() {
  case "$1" in
    *money*|*payment*|*auth*|*session*|*rls*|*polic*|*migration*|*secret*|*security*|*credential*|*env*|*deploy-config*|*reflect*)
      echo EXCLUDED ;;
    lockfile-drift|dep-bump|dep-sync|format|lint-autofix)
      echo CLASS_A ;;
    *)  # everything else is a code change -> Class B (still fully gated + human-reviewable)
      echo CLASS_B ;;
  esac
}