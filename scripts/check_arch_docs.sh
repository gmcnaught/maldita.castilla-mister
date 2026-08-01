#!/usr/bin/env bash
# check_arch_docs.sh — validate docs/architecture Markdown files.
# 1) Every ```mermaid fence must parse (rendered via mmdc).
# 2) Every `backtick` path starting with a known repo prefix must exist
#    relative to the MisterFPGA-Projects root.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # maldita.castilla-mister
PROJ="$(cd "$ROOT/.." && pwd)"                     # MisterFPGA-Projects
TMP="${TMPDIR:-/tmp}/arch-docs-check.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
FILES=("$@")
[ ${#FILES[@]} -eq 0 ] && FILES=("$ROOT"/docs/architecture/*.md)
FAILFILE="$TMP/fail"
: > "$FAILFILE"
fidx=0
for f in "${FILES[@]}"; do
  [ -e "$f" ] || continue
  # --- mermaid fences ---
  # Prefix temp names with a per-argument index so two same-basename files from
  # different directories cannot collide when passed explicitly.
  fidx=$((fidx + 1))
  base="${fidx}-$(basename "$f" .md)"
  awk -v out_prefix="$TMP/$base" '
    /^```mermaid/{n++; out=sprintf("%s-%d.mmd", out_prefix, n); inblk=1; next}
    /^```/{inblk=0; next}
    inblk{print > out}
  ' "$f"
  for m in "$TMP/$base"-*.mmd; do
    [ -e "$m" ] || continue
    if ! npx -y @mermaid-js/mermaid-cli -i "$m" -o "$m.svg" >/dev/null 2>&1; then
      echo "FAIL mermaid: $f ($(basename "$m"))"
      echo x >> "$FAILFILE"
    fi
  done
  # --- cross-repo paths ---
  # Every prefix is bounded by a trailing '/' so a token like
  # "mister-gmloader-archive" cannot false-positive as a repo-relative path.
  grep -o '`[^`]*`' "$f" | tr -d '`' | \
    grep -E '^(maldita\.castilla-mister|mister-gmloader|external|docs|3rdparty)/' | sort -u > "$TMP/paths.$base"
  while read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      external/*) pbase="$ROOT";;
      docs/*) pbase="$ROOT";;
      3rdparty/*) pbase="$ROOT/external/gmloader-next";;
      *) pbase="$PROJ";;
    esac
    # strip trailing :line refs
    p2="${p%%:*}"
    if [ ! -e "$pbase/$p2" ]; then
      echo "FAIL path: $f -> $p"
      echo x >> "$FAILFILE"
    fi
  done < "$TMP/paths.$base"
done
if [ -s "$FAILFILE" ]; then
  exit 1
fi
exit 0
