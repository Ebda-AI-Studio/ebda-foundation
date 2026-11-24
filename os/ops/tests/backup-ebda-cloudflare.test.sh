#!/usr/bin/env bash
# backup-ebda-cloudflare.sh: a HEALTHY pull is silent; a corrupt / collapsed / stale / missing backup pages ONCE
# and exits non-zero; missing credentials FAIL LOUD. Nothing here touches R2 or Telegram: the bucket is a local
# directory (EBDA_CF_BACKUP_SRC) and notify.sh is a recording stub.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; OPS="$(pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
_pass=0; _fail=0
pass() { echo "PASS: $1"; _pass=$((_pass+1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail+1)); }

D0="$(date -u +%Y-%m-%d)"; D1="$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d yesterday +%Y-%m-%d)"
D6="$(date -u -v-6d +%Y-%m-%d 2>/dev/null || date -u -d '6 days ago' +%Y-%m-%d)"

# mk_table <dir> <table> <rows>: NDJSON (header + rows) in the exact shape the Worker writes
mk_table() { { echo '["id","v"]'; i=0; while [ "$i" -lt "$3" ]; do echo "[$i,\"x$i\"]"; i=$((i+1)); done; } > "$1/$2.ndjson"; }
mk_manifest() { # <dir> <table:rows>...
  local dir="$1"; shift; local j='{}'
  for tr in "$@"; do t="${tr%%:*}"; r="${tr##*:}"; mk_table "$dir" "$t" "$r"
    j="$(jq -c --arg t "$t" --argjson r "$r" --arg s "$(shasum -a 256 "$dir/$t.ndjson" | awk '{print $1}')" '.[$t]={rows:$r,sha256:$s}' <<<"$j")"; done
  jq -n --argjson t "$j" '{version:1,storeId:"x",takenAt:"2026-11-01T03:00:00Z",tables:$t}' > "$dir/manifest.json"
}
mk_bucket() { # <name> -> bucket dir with a healthy store (D1, D0) + d1 db + ok sweep report
  local b="$TMP/$1"
  mkdir -p "$b/store-do-backups/s1/$D1" "$b/store-do-backups/s1/$D0" "$b/d1-backups/PLATFORM_DB/$D0" "$b/ops-reports/backup-sweep"
  mk_manifest "$b/store-do-backups/s1/$D1" products:20 orders:20
  mk_manifest "$b/store-do-backups/s1/$D0" products:21 orders:20
  mk_manifest "$b/d1-backups/PLATFORM_DB/$D0" users:5
  echo '{"ok":true}' > "$b/ops-reports/backup-sweep/$D0.json"
  printf '%s' "$b"
}
run() { # <tag> <bucket> [env...] -> sets RC, LOG, NOTIFY count
  local tag="$1" b="$2"; shift 2
  local r="$TMP/run-$tag"; mkdir -p "$r"
  cp "${SCRIPT:-$OPS/backup-ebda-cloudflare.sh}" "$r/backup-ebda-cloudflare.sh"; ln -sfn "$OPS/lib" "$r/lib"
  printf '#!/usr/bin/env bash\necho CALLED "$1" >> "%s/notify-%s.log"\n' "$TMP" "$tag" > "$r/notify.sh"; chmod +x "$r/notify.sh"
  : > "$TMP/notify-$tag.log"
  env BACKUP_CAFFEINATED=1 HOME="$TMP/home-$tag" EBDA_CF_BACKUP_ROOT="$TMP/out-$tag" EBDA_CF_BACKUP_SRC="$b" "$@" bash "$r/backup-ebda-cloudflare.sh" > "$TMP/log-$tag" 2>&1
  RC=$?; N=$(grep -c '^CALLED' "$TMP/notify-$tag.log" 2>/dev/null) || N=0
}
mkdir -p "$TMP"/home-{a,b,c,d,e,f,g,h,i1,i2,i3,j1,j2,k1,m1,m2,m3}

B="$(mk_bucket a)"; run a "$B"
[ "$RC" = 0 ] && [ "$N" = 0 ] && pass "A healthy pull exits 0 and pages zero times" || { fail "A healthy pull (rc=$RC pages=$N)"; cat "$TMP/log-a"; }
grep -q "ok store s1" "$TMP/log-a" && grep -q "ok d1 PLATFORM_DB" "$TMP/log-a" && pass "A each store and each D1 database is verified by name" || fail "A per-unit ok lines missing"

B="$(mk_bucket b)"; echo '["id","v"]' > "$B/store-do-backups/s1/$D0/orders.ndjson"; echo '[1,"tampered"]' >> "$B/store-do-backups/s1/$D0/orders.ndjson"
run b "$B"
[ "$RC" != 0 ] && [ "$N" = 1 ] && grep -q "FAILED verification" "$TMP/log-b" && pass "B a corrupted table file fails verification and pages exactly once" || { fail "B corrupt (rc=$RC pages=$N)"; cat "$TMP/log-b"; }

B="$(mk_bucket c)"; rm -rf "$B/store-do-backups/s1/$D0"; mkdir -p "$B/store-do-backups/s1/$D0"; mk_manifest "$B/store-do-backups/s1/$D0" products:1 orders:1
run c "$B"
[ "$RC" != 0 ] && [ "$N" = 1 ] && grep -q COLLAPSED "$TMP/log-c" && pass "C a row-count collapse (40 -> 2) is an error, not a backup" || { fail "C collapse (rc=$RC pages=$N)"; cat "$TMP/log-c"; }

B="$(mk_bucket d)"; mv "$B/store-do-backups/s1/$D0" "$B/store-do-backups/s1/$D6"; mv "$B/store-do-backups/s1/$D1" "$B/store-do-backups/s1/$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)"
run d "$B"
[ "$RC" != 0 ] && grep -q "d old, limit 2d" "$TMP/log-d" && pass "D a store whose newest backup is 6 days old is stale" || { fail "D stale (rc=$RC)"; cat "$TMP/log-d"; }

B="$(mk_bucket e)"; echo '{"ok":false}' > "$B/ops-reports/backup-sweep/$D0.json"; run e "$B"
[ "$RC" != 0 ] && grep -q "ok:false" "$TMP/log-e" && pass "E a failed Worker sweep report fails the pull" || fail "E sweep report ok:false not caught"

B="$(mk_bucket f)"; rm -rf "$B/store-do-backups" "$B/d1-backups"; run f "$B"
[ "$RC" != 0 ] && grep -q "nothing to verify" "$TMP/log-f" && pass "F an empty mirror fails (zero backups is the incident)" || { fail "F empty mirror not caught (rc=$RC)"; cat "$TMP/log-f"; }

run g "" EBDA_CF_BACKUP_SRC= EBDA_R2_PULL_CREDS="$TMP/nope"
[ "$RC" = 2 ] && [ "$N" = 1 ] && grep -q "FATAL" "$TMP/log-g" && pass "G missing credentials: FATAL, exit 2, one page" || { fail "G creds (rc=$RC pages=$N)"; cat "$TMP/log-g"; }

# mutation control: with the verification call neutered, case B must stop failing (so B proves the check works)
sed 's/fail "\$label: \$newest FAILED verification"; return;/:;/' "$OPS/backup-ebda-cloudflare.sh" > "$TMP/mut.sh"
B="$(mk_bucket h)"; echo '["id","v"]' > "$B/store-do-backups/s1/$D0/orders.ndjson"; echo '[1,"tampered"]' >> "$B/store-do-backups/s1/$D0/orders.ndjson"
SCRIPT="$TMP/mut.sh" run h "$B"; unset SCRIPT
if cmp -s "$TMP/mut.sh" "$OPS/backup-ebda-cloudflare.sh"; then fail "MC the mutation did not change the script"
elif [ "$RC" = 0 ]; then pass "MC removing the verification makes the corrupted-backup case pass (so case B is a real test)"; else fail "MC mutation still failed rc=$RC"; cat "$TMP/log-h"; fi


# ---- review fixes: fail CLOSED -------------------------------------------------------------------------------
# I1 integrity: empty tables object / non-integer rows / short sha must FAIL, never pass vacuously
B="$(mk_bucket i1)"; jq '.tables={}' "$B/store-do-backups/s1/$D0/manifest.json" > "$TMP/m" && mv "$TMP/m" "$B/store-do-backups/s1/$D0/manifest.json"
run i1 "$B"; [ "$RC" != 0 ] && grep -q "no tables object" "$TMP/log-i1" && pass "I1a a manifest with zero tables fails (no vacuous pass)" || { fail "I1a empty tables (rc=$RC)"; cat "$TMP/log-i1"; }
B="$(mk_bucket i2)"; jq '.tables.orders.rows="abc"' "$B/store-do-backups/s1/$D0/manifest.json" > "$TMP/m" && mv "$TMP/m" "$B/store-do-backups/s1/$D0/manifest.json"
run i2 "$B"; [ "$RC" != 0 ] && grep -q "not an integer" "$TMP/log-i2" && pass "I1b a non-integer row count fails" || { fail "I1b rows (rc=$RC)"; cat "$TMP/log-i2"; }
B="$(mk_bucket i3)"; jq '.tables.orders.sha256="deadbeef"' "$B/store-do-backups/s1/$D0/manifest.json" > "$TMP/m" && mv "$TMP/m" "$B/store-do-backups/s1/$D0/manifest.json"
run i3 "$B"; [ "$RC" != 0 ] && grep -q "64 hex" "$TMP/log-i3" && pass "I1c a malformed sha256 fails" || { fail "I1c sha (rc=$RC)"; cat "$TMP/log-i3"; }

# I2 freshness: a day folder dated in the future is an error and is never picked as newest
FUT="$(date -u -v+10d +%Y-%m-%d 2>/dev/null || date -u -d '10 days' +%Y-%m-%d)"
B="$(mk_bucket j1)"; cp -R "$B/store-do-backups/s1/$D0" "$B/store-do-backups/s1/$FUT"
run j1 "$B"; [ "$RC" != 0 ] && grep -q "dated in the future" "$TMP/log-j1" && pass "I2a a future-dated day folder is an error" || { fail "I2a future (rc=$RC)"; cat "$TMP/log-j1"; }
B="$(mk_bucket j2)"; mv "$B/store-do-backups/s1/$D0" "$B/store-do-backups/s1/$D6"; mv "$B/store-do-backups/s1/$D1" "$B/store-do-backups/s1/$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)"; cp -R "$B/store-do-backups/s1/$D6" "$B/store-do-backups/s1/$FUT"
run j2 "$B"; [ "$RC" != 0 ] && grep -q "d old, limit 2d" "$TMP/log-j2" && pass "I2b a future folder cannot mask a stale store (newest real backup is still 6d old)" || { fail "I2b mask (rc=$RC)"; cat "$TMP/log-j2"; }

# I3 write-once mirror: a second pull where R2 changed an already-mirrored file must alert and keep the good copy
B="$(mk_bucket k1)"; run k1 "$B"
[ "$RC" = 0 ] || fail "I3 setup pull failed"
GOOD="$(shasum -a 256 "$TMP/out-k1/mirror/store-do-backups/s1/$D0/orders.ndjson" | awk '{print $1}')"
echo '[999,"rewritten-by-attacker"]' >> "$B/store-do-backups/s1/$D0/orders.ndjson"
mkdir -p "$TMP/home-k1"; r="$TMP/run-k1"; : > "$TMP/notify-k1.log"
env BACKUP_CAFFEINATED=1 HOME="$TMP/home-k1" EBDA_CF_BACKUP_ROOT="$TMP/out-k1" EBDA_CF_BACKUP_SRC="$B" bash "$r/backup-ebda-cloudflare.sh" > "$TMP/log-k1b" 2>&1; RC=$?; N=$(grep -c '^CALLED' "$TMP/notify-k1.log") || N=0
AFTER="$(shasum -a 256 "$TMP/out-k1/mirror/store-do-backups/s1/$D0/orders.ndjson" | awk '{print $1}')"
[ "$RC" != 0 ] && [ "$N" = 1 ] && grep -q "IMMUTABILITY VIOLATION" "$TMP/log-k1b" && [ "$GOOD" = "$AFTER" ] && pass "I3 a rewritten remote file is NOT copied over the mirror, and it pages once" || { fail "I3 immutability (rc=$RC pages=$N same=$([ "$GOOD" = "$AFTER" ] && echo y || echo n))"; cat "$TMP/log-k1b"; }

# mutation controls for the three fixes
mutcheck() { # <name> <sed-expr> <case-bucket-builder-fn> <expect-log-grep>
  :
}
sed 's/jq -e .\.tables | type == "object" and length > 0. "\$m" >\/dev\/null 2>&1/true/' "$OPS/backup-ebda-cloudflare.sh" > "$TMP/mut1.sh"
if cmp -s "$TMP/mut1.sh" "$OPS/backup-ebda-cloudflare.sh"; then fail "MC1 mutation did not change the script"; else
  B="$(mk_bucket m1)"; jq '.tables={}' "$B/store-do-backups/s1/$D0/manifest.json" > "$TMP/m" && mv "$TMP/m" "$B/store-do-backups/s1/$D0/manifest.json"
  SCRIPT="$TMP/mut1.sh" run m1 "$B"; unset SCRIPT
  grep -q "no tables object" "$TMP/log-m1" && fail "MC1 guard still fired with the jq -e check removed" || pass "MC1 without the tables check the empty-manifest case no longer reports it (guard is what catches it)"; fi
sed 's/-gt 86400 \]; then fail/-gt 86400000 ]; then :; fail/' "$OPS/backup-ebda-cloudflare.sh" > "$TMP/mut2.sh"
if cmp -s "$TMP/mut2.sh" "$OPS/backup-ebda-cloudflare.sh"; then fail "MC2 mutation did not change the script"; else
  B="$(mk_bucket m2)"; cp -R "$B/store-do-backups/s1/$D0" "$B/store-do-backups/s1/$FUT"
  SCRIPT="$TMP/mut2.sh" run m2 "$B"; unset SCRIPT
  grep -q "dated in the future" "$TMP/log-m2" && fail "MC2 guard still fired" || pass "MC2 without the future-date guard case I2a no longer reports it"; fi
sed 's/\*) fail "IMMUTABILITY VIOLATION.*;;/*) cp "$f" "$dest" ;;/' "$OPS/backup-ebda-cloudflare.sh" > "$TMP/mut3.sh"
if cmp -s "$TMP/mut3.sh" "$OPS/backup-ebda-cloudflare.sh"; then fail "MC3 mutation did not change the script"; else
  B="$(mk_bucket m3)"; SCRIPT="$TMP/mut3.sh" run m3 "$B"; r="$TMP/run-m3"
  echo '[999,"x"]' >> "$B/store-do-backups/s1/$D0/orders.ndjson"
  env BACKUP_CAFFEINATED=1 HOME="$TMP/home-m3" EBDA_CF_BACKUP_ROOT="$TMP/out-m3" EBDA_CF_BACKUP_SRC="$B" bash "$r/backup-ebda-cloudflare.sh" > "$TMP/log-m3b" 2>&1; unset SCRIPT
  grep -q "IMMUTABILITY VIOLATION" "$TMP/log-m3b" && fail "MC3 guard still fired" || pass "MC3 without the write-once branch the overwrite goes through silently (guard is what stops it)"; fi

# ---- paged tables (manifest.tables[t].parts, Ebda Store P2-4) ----------------------------------------------------
# mk_paged <dir> <table> <rows-per-part...>: writes <table>.part-NNNN.ndjson files and the Worker-shaped manifest entry
mk_paged() {
  local dir="$1" t="$2"; shift 2; local n=0 total=0 parts='[]' shas="" f r i psha
  for r in "$@"; do
    n=$((n+1)); f="$(printf '%s.part-%04d.ndjson' "$t" "$n")"
    { echo '["id","v"]'; i=0; while [ "$i" -lt "$r" ]; do echo "[$((total+i)),\"p$n\"]"; i=$((i+1)); done; } > "$dir/$f"
    psha="$(shasum -a 256 "$dir/$f" | awk '{print $1}')"; shas="${shas:+$shas$'\n'}$psha"; total=$((total+r))
    parts="$(jq -c --arg f "$f" --argjson r "$r" --arg s "$psha" '.+[{file:$f,rows:$r,sha256:$s}]' <<<"$parts")"
  done
  jq --arg t "$t" --argjson rows "$total" --arg s "$(printf '%s' "$shas" | shasum -a 256 | awk '{print $1}')" --argjson p "$parts" \
    '.tables[$t]={rows:$rows,sha256:$s,parts:$p}' "$dir/manifest.json" > "$dir/m.tmp" && mv "$dir/m.tmp" "$dir/manifest.json"
}
mk_paged_bucket() { # <name> -> healthy bucket whose D0 orders table is paged into 3 parts (30 rows)
  local b; b="$(mk_bucket "$1")"; rm -f "$b/store-do-backups/s1/$D0/orders.ndjson"
  mk_paged "$b/store-do-backups/s1/$D0" orders 10 12 8; printf '%s' "$b"
}
mkdir -p "$TMP"/home-{p1,p2,p3,p4,p5,p6,p7,p8,p9}

B="$(mk_paged_bucket p1)"; run p1 "$B"
[ "$RC" = 0 ] && [ "$N" = 0 ] && grep -q "ok store s1" "$TMP/log-p1" && pass "P1 a healthy paged table (3 parts) verifies and pages zero times" || { fail "P1 healthy paged (rc=$RC pages=$N)"; cat "$TMP/log-p1"; }

B="$(mk_paged_bucket p2)"; rm "$B/store-do-backups/s1/$D0/orders.part-0002.ndjson"; run p2 "$B"
[ "$RC" != 0 ] && [ "$N" = 1 ] && grep -q "manifest lists 3 parts but 2 part files" "$TMP/log-p2" && pass "P2 a missing part fails on the part count (the old script would not even look)" || { fail "P2 missing part (rc=$RC pages=$N)"; cat "$TMP/log-p2"; }

B="$(mk_paged_bucket p3)"; echo '[999,"tamper"]' >> "$B/store-do-backups/s1/$D0/orders.part-0003.ndjson"; run p3 "$B"
[ "$RC" != 0 ] && grep -q "part-0003.ndjson checksum differs" "$TMP/log-p3" && pass "P3 a tampered part fails its sha256" || { fail "P3 tampered part (rc=$RC)"; cat "$TMP/log-p3"; }

B="$(mk_paged_bucket p4)"; cp "$B/store-do-backups/s1/$D0/orders.part-0001.ndjson" "$B/store-do-backups/s1/$D0/orders.part-0004.ndjson"; run p4 "$B"
[ "$RC" != 0 ] && grep -q "lists 3 parts but 4 part files" "$TMP/log-p4" && pass "P4 an extra part file on disk fails" || { fail "P4 extra part (rc=$RC)"; cat "$TMP/log-p4"; }

B="$(mk_paged_bucket p5)"; M="$B/store-do-backups/s1/$D0/manifest.json"; jq '.tables.orders.rows=31' "$M" > "$TMP/m" && mv "$TMP/m" "$M"; run p5 "$B"
[ "$RC" != 0 ] && grep -q "parts hold 30 rows, manifest says 31" "$TMP/log-p5" && pass "P5 part rows that do not add up to the table rows fail" || { fail "P5 row sum (rc=$RC)"; cat "$TMP/log-p5"; }

B="$(mk_paged_bucket p6)"; M="$B/store-do-backups/s1/$D0/manifest.json"; jq '.tables.orders.sha256=("a"*64)' "$M" > "$TMP/m" && mv "$TMP/m" "$M"; run p6 "$B"
[ "$RC" != 0 ] && grep -q "table digest differs" "$TMP/log-p6" && pass "P6 a table digest that is not the digest of its parts fails" || { fail "P6 digest (rc=$RC)"; cat "$TMP/log-p6"; }

B="$(mk_paged_bucket p7)"; M="$B/store-do-backups/s1/$D0/manifest.json"; jq '.tables.orders.parts[0].file="../x.ndjson"' "$M" > "$TMP/m" && mv "$TMP/m" "$M"; run p7 "$B"
[ "$RC" != 0 ] && grep -q "unsafe part file name" "$TMP/log-p7" && pass "P7 a part file name that escapes the day folder is rejected" || { fail "P7 unsafe name (rc=$RC)"; cat "$TMP/log-p7"; }

# P9: part 0002 is replaced by a second listing of part 0001; rows and table digest are recomputed so that ONLY the uniqueness check can catch it
B="$(mk_paged_bucket p9)"; M="$B/store-do-backups/s1/$D0/manifest.json"
jq '.tables.orders.parts[1]=.tables.orders.parts[0] | .tables.orders.rows=([.tables.orders.parts[].rows]|add)' "$M" > "$TMP/m" && mv "$TMP/m" "$M"
jq --arg s "$(jq -j '[.tables.orders.parts[].sha256]|join("\n")' "$M" | shasum -a 256 | awk '{print $1}')" '.tables.orders.sha256=$s' "$M" > "$TMP/m" && mv "$TMP/m" "$M"
run p9 "$B"
[ "$RC" != 0 ] && grep -q "lists part 'orders.part-0001.ndjson' more than once" "$TMP/log-p9" && pass "P9 a manifest listing the same part twice fails on uniqueness (count, rows and digest were made consistent)" || { fail "P9 duplicate part (rc=$RC)"; cat "$TMP/log-p9"; }

# mutation control: the OLD logic (hash only <table>.ndjson) cannot see a paged table at all
sed 's/if \[ "\$(jq -r --arg t "\$t" .\.tables\[\$t\] | has("parts").*/if false; then/' "$OPS/backup-ebda-cloudflare.sh" > "$TMP/mut4.sh"
if cmp -s "$TMP/mut4.sh" "$OPS/backup-ebda-cloudflare.sh"; then fail "MC4 mutation did not change the script"; else
  B="$(mk_paged_bucket p8)"; rm "$B/store-do-backups/s1/$D0/orders.part-0002.ndjson"
  SCRIPT="$TMP/mut4.sh" run p8 "$B"; unset SCRIPT
  grep -q "part files" "$TMP/log-p8" && fail "MC4 part check still fired" || pass "MC4 without the parts branch a paged table is reported as a plain missing file (parts logic is what verifies it)"; fi

echo; echo "passed=$_pass failed=$_fail"; [ "$_fail" = 0 ]
