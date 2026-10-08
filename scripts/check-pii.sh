#!/usr/bin/env bash
# Fail if a staged change contains a PII / outreach pattern that doesn't
# belong in this (research) repo. Private names, draft emails, recruit
# lists, meeting-prep notes with named people, and speculative co-author
# bench entries all belong in `~/Documents/apps/crm/`, not here.
#
# Why this exists: an audit on 2026-10-08 found three local-only commits
# with 7+ unconsented names + a draft outreach email, which were caught
# before leaving the machine but exemplify a drift pattern that will
# recur without an enforcement layer. See OUTREACH_POLICY.md.
#
# Modeled after fleet/scripts/scan-secrets.sh (same CLI, same failure
# contract, same chained-hook pattern).
#
#   check-pii.sh            scan tracked files
#   check-pii.sh --staged   scan only what is staged (for the pre-commit hook)
#
# Exit codes:
#   0 — no PII / outreach markers found (or all suppressed with `# allow-pii:`)
#   1 — flagged content requires human review
#   2 — watchlist missing or unreadable (fail-closed on config error)
#
# Escape hatch: `git commit --no-verify` bypasses the whole hook chain.
#   Prefer adding an inline `# allow-pii: <reason>` or whitelisting the
#   name in `~/.config/emrgi/pii-watchlist` so the pattern is auditable.

set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WATCHLIST="${EMRGI_PII_WATCHLIST:-$HOME/.config/emrgi/pii-watchlist}"

# ---- Pick file set ---------------------------------------------------
if [[ "${1:-}" == "--staged" ]]; then
    mapfile -t FILES < <(git diff --cached --name-only --diff-filter=ACM)
else
    mapfile -t FILES < <(git ls-files)
fi
[[ ${#FILES[@]} -eq 0 ]] && exit 0

# ---- Load watchlist --------------------------------------------------
# Non-blank, non-comment, non-`allow:` lines → FLAG patterns.
# `allow: FOO` lines → WHITELIST patterns (suppress a flag match whose
# line also matches a WHITELIST pattern).
FLAG_PATTERNS=()
ALLOW_PATTERNS=()
if [[ -r "$WATCHLIST" ]]; then
    while IFS= read -r line; do
        # strip comment + trim
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        if [[ "$line" == allow:* ]]; then
            ALLOW_PATTERNS+=("${line#allow:}")
        else
            FLAG_PATTERNS+=("$line")
        fi
    done < "$WATCHLIST"
else
    echo "check-pii: watchlist $WATCHLIST not found." >&2
    echo "  Create it (see OUTREACH_POLICY.md for the seed list) or set" >&2
    echo "  EMRGI_PII_WATCHLIST to a different path." >&2
    exit 2
fi

# ---- Built-in patterns that fire regardless of watchlist -------------
# Email addresses, except known-public ecosystem addresses.
# The allow-list intentionally covers:
#   - project's own email surface (info@emburden.org, Eric's public addresses)
#   - noreply / users.noreply (git plumbing)
#   - .gov / .edu general-contact addresses (public-records offices, agencies)
# A specific name's private email (e.g. edbaker@umass.edu) belongs on the
# PII watchlist as a FLAG line, which will still fire regardless.
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
EMAIL_ALLOW_RE='info@emburden\.org|eric@scheier\.org|eric\.scheier@gmail\.com|@users\.noreply\.github\.com|noreply@|^Reply-To:|@example\.(com|org)|@your\.?(domain|email)|@cdc\.gov|@cpuc\.ca\.gov|@dshs\.texas\.gov|@mortality\.org|@sonoma-county\.org|@ecy\.wa\.gov|@dhhr\.wv\.gov|@dec\.ny\.gov|@energy\.ca\.gov|@eia\.gov|@epa\.gov|@noaa\.gov|@dnr\..*\.gov|@mass\.gov'

# Draft-email + recruit-list markers.
DRAFT_PATTERNS=(
    '^\*\*To:\*\*'
    '^\*\*From:\*\*'
    '^\*\*Subject:\*\*'
    '^\*\*Cc:\*\*'
    '^In-reply-to:'
    "cc'd throughout"
    'recruit bench'
    'draft outreach'
    'Hi [A-Z][a-z]+,'
    'Dear [A-Z][a-z]+,'
)

HITS=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Helper: does $1 contain any ALLOW_PATTERN as a substring (case-insensitive)?
is_allowed() {
    local line_lower="${1,,}"
    local p
    for p in "${ALLOW_PATTERNS[@]}"; do
        local p_lower="${p,,}"
        p_lower="${p_lower#"${p_lower%%[![:space:]]*}"}"
        [[ -n "$p_lower" && "$line_lower" == *"$p_lower"* ]] && return 0
    done
    # Inline per-line escape hatch
    [[ "$line_lower" == *"# allow-pii:"* ]] && return 0
    return 1
}

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    # Don't scan ourselves (contains every pattern it searches for).
    case "$f" in
        scripts/check-pii.sh|OUTREACH_POLICY.md) continue ;;
    esac
    # Skip binaries, build artifacts, data caches.
    case "$f" in
        *.png|*.pdf|*.pptx|*.rds|*.parquet|*.zip|*.tar.gz|*.docx|*.xlsx) continue ;;
    esac

    file_hits=""

    # ---- Watchlist name hits ----
    for pat in "${FLAG_PATTERNS[@]}"; do
        while IFS=: read -r lineno line; do
            [[ -z "$lineno" ]] && continue
            is_allowed "$line" && continue
            file_hits+=$'\n'"  L${lineno}: [name] ${pat} → ${line}"
        done < <(grep -in -F "$pat" "$f" 2>/dev/null | head -5)
    done

    # ---- Email hits (block-list minus allow-list) ----
    while IFS=: read -r lineno line; do
        [[ -z "$lineno" ]] && continue
        # Skip the ecosystem's own public email addresses.
        if echo "$line" | grep -qE "$EMAIL_ALLOW_RE"; then
            # Only skip if the ONLY matched address is on the allow list.
            # If both allowed + non-allowed addresses appear on the same
            # line, fall through to the flag path.
            line_without_allowed=$(echo "$line" | sed -E "s/($EMAIL_ALLOW_RE)[A-Za-z0-9._%+-]*//g")
            if ! echo "$line_without_allowed" | grep -qE "$EMAIL_RE"; then
                continue
            fi
        fi
        is_allowed "$line" && continue
        file_hits+=$'\n'"  L${lineno}: [email] ${line}"
    done < <(grep -nE "$EMAIL_RE" "$f" 2>/dev/null | head -5)

    # ---- Draft-email marker hits ----
    for pat in "${DRAFT_PATTERNS[@]}"; do
        while IFS=: read -r lineno line; do
            [[ -z "$lineno" ]] && continue
            is_allowed "$line" && continue
            file_hits+=$'\n'"  L${lineno}: [draft] ${pat} → ${line}"
        done < <(grep -nE "$pat" "$f" 2>/dev/null | head -3)
    done

    if [[ -n "$file_hits" ]]; then
        echo "PII? $f$file_hits"
        HITS=1
    fi
done

if [[ "$HITS" -eq 1 ]]; then
    echo
    echo "check-pii: content requires human review. Options:"
    echo "  - move the file into crm/dissertation/ (see OUTREACH_POLICY.md)"
    echo "  - add an inline '# allow-pii: <reason>' near the flagged line"
    echo "  - whitelist the name in $WATCHLIST (allow: <name>)"
    echo "  - bypass: git commit --no-verify (visible escape hatch)"
    exit 1
fi
exit 0
