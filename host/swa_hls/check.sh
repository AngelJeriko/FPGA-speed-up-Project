#!/usr/bin/env bash
# Acceptance suite for the synthesizable kernel (host/swa_hls/ksw_hls.h).
#
# Three invariants, in increasing order of importance:
#   1. the integer division transform is exact (exhaustive, data-independent)
#   2. on the default-parameter golden set, all three models agree with bwa-mem2
#   3. hls == reference on EVERY committed vector, including the ones where the
#      reference itself disagrees with bwa-mem2 -- the HLS kernel is a port of
#      ksw_extend2, so it must track the port, not paper over its quirks.
set -euo pipefail
cd "$(dirname "$0")"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

say () { printf '%-46s %s\n' "$1" "$2"; }
grab () { grep "^$2" "$1" | sed 's/.*: //;s/ .*//'; }

echo "== 1. division transform (exhaustive) =="
./test_div_transform | tail -1

echo
echo "== 2. default-parameter golden set =="
zcat vectors/ecoli_swa_2k.bin.gz > "$tmp/g.bin"
./replay_swa "$tmp/g.bin" > "$tmp/g.out"
for line in "reference vs golden" "hls       vs golden" "hls       vs reference"; do
    r=$(grab "$tmp/g.out" "$line")
    say "$line" "$r"
    [ "$r" = PASS ] || fail=1
done

echo
echo "== 3. hls == reference on every vector =="
for v in vectors/*.bin.gz; do
    zcat "$v" > "$tmp/v.bin"
    ./replay_swa "$tmp/v.bin" > "$tmp/v.out" 2>&1 || true
    r=$(grab "$tmp/v.out" "hls       vs reference")
    say "$(basename "$v")" "hls-vs-reference: $r"
    [ "$r" = PASS ] || fail=1
done

echo
echo "== 4. characterised divergences must stay red =="
# These are the records where ksw_extend2 disagrees with bwa-mem2. If one starts
# agreeing, the edge moved and docs/swa_golden_capture.md is stale.
for v in vectors/divergent_*.bin.gz; do
    zcat "$v" > "$tmp/v.bin"
    ./replay_swa "$tmp/v.bin" > "$tmp/v.out" 2>&1 || true
    r=$(grab "$tmp/v.out" "reference vs golden")
    say "$(basename "$v")" "reference-vs-golden: $r (want FAIL)"
    [ "$r" = FAIL ] || fail=1
done

echo
[ "$fail" = 0 ] && echo "check: OK" || echo "check: FAILED"
exit $fail
