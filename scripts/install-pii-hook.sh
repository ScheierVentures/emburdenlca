#!/usr/bin/env bash
# Install the PII / outreach pre-commit hook. Idempotent + hook-chaining aware:
# if a pre-commit hook already exists, we prepend our check and keep the
# existing one as a tail call. Run from any directory inside this repo.
#
# Usage:
#   ./scripts/install-pii-hook.sh         # install
#   ./scripts/install-pii-hook.sh --uninstall
#   ./scripts/install-pii-hook.sh --check  # dry-run: print what would happen
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { echo "not in a git repo"; exit 1; })
HOOK="$ROOT/.git/hooks/pre-commit"
MARK="# installed by scripts/install-pii-hook.sh"
SCANNER_REL="scripts/check-pii.sh"

CMD="${1:-install}"

case "$CMD" in
    --uninstall|uninstall)
        if [[ -f "$HOOK" ]] && grep -q "$MARK" "$HOOK"; then
            # Remove the block between our marker + the trailing EOF marker.
            awk -v mark="$MARK" '
                $0 == mark {skipping=1; next}
                skipping && /^# end install-pii-hook/ {skipping=0; next}
                !skipping {print}
            ' "$HOOK" > "$HOOK.tmp" && mv "$HOOK.tmp" "$HOOK"
            chmod +x "$HOOK"
            echo "uninstalled check-pii from $HOOK"
        else
            echo "nothing to uninstall at $HOOK"
        fi
        exit 0
        ;;
    --check|check)
        echo "would install into $HOOK, running $ROOT/$SCANNER_REL --staged"
        [[ -f "$HOOK" ]] && echo "existing hook will be preserved + chained"
        exit 0
        ;;
    install|'')
        :
        ;;
    *)
        echo "unknown command: $CMD. use install | --uninstall | --check" >&2
        exit 2
        ;;
esac

if [[ -f "$HOOK" ]] && grep -q "$MARK" "$HOOK"; then
    echo "already installed at $HOOK (marker present; re-run with --uninstall first to reinstall)"
    exit 0
fi

mkdir -p "$(dirname "$HOOK")"

if [[ -f "$HOOK" ]]; then
    # Chain: prepend our block in front of the existing hook body.
    EXISTING=$(cat "$HOOK")
    cat > "$HOOK" <<EOF
#!/usr/bin/env bash
$MARK
# Chained — this block runs first; the original hook body runs after.
set -e
"\$(git rev-parse --show-toplevel)/$SCANNER_REL" --staged
# end install-pii-hook
# ---- original pre-commit hook ----
EOF
    # Append original hook body (minus any existing shebang on line 1).
    echo "$EXISTING" | tail -n +2 >> "$HOOK"
else
    cat > "$HOOK" <<EOF
#!/usr/bin/env bash
$MARK
set -e
"\$(git rev-parse --show-toplevel)/$SCANNER_REL" --staged
# end install-pii-hook
EOF
fi
chmod +x "$HOOK"
echo "installed check-pii pre-commit hook at $HOOK"
echo
echo "Verify:"
echo "  $ROOT/$SCANNER_REL --staged       # should exit 0 with no staged changes"
echo "  git add <some outreach file> && git commit -m test   # should fail"
