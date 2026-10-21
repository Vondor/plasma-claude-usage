#!/bin/sh
# Read-only reader for the OAuth login cached by Claude Desktop.
#
# The widget normally reads ~/.claude/.credentials.json, which only exists
# once the Claude Code CLI has been logged in. Claude Desktop keeps its own
# login in <config dir>/config.json under "oauth:tokenCacheV2" (older builds:
# "oauth:tokenCache"), encrypted with Electron's safeStorage. This script
# decrypts that value and prints it in the same shape as the CLI file, so the
# rest of the widget does not need to know where the token came from:
#
#   {"source":"desktop","claudeAiOauth":{"accessToken":"...","expiresAt":<ms>}}
#
# Prints nothing (and exits 0) when there is no usable Desktop login.
#
# It never touches the refresh token and never writes to Desktop's files:
# refresh tokens rotate, so using one here would sign Desktop out. When the
# access token has expired the widget asks the user to open Claude Desktop,
# which refreshes it itself.
#
# Linux only. Needs openssl >= 3.0 (for `openssl kdf`) and, if Desktop keeps
# its key in the system keyring ("v11" values), secret-tool (libsecret) or
# kwallet-query. Without a keyring Desktop falls back to Chromium's fixed
# password ("v10" values), which needs nothing extra.
#
# Usage: desktop_creds.sh [--diagnose]
#   --diagnose  explain on stderr why no token was found. Prints key names
#               and counts only, never token values.
#
# Environment:
#   CLAUDE_DESKTOP_DIR  Claude Desktop config folder
#                       (default: ${XDG_CONFIG_HOME:-$HOME/.config}/Claude)

DIAG=""
[ "$1" = "--diagnose" ] && DIAG=1

log() {
    [ -n "$DIAG" ] && printf 'desktop_creds: %s\n' "$*" >&2
    return 0
}

DIR="${CLAUDE_DESKTOP_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/Claude}"
CFG="$DIR/config.json"
if [ ! -r "$CFG" ]; then
    log "no readable $CFG (Claude Desktop not installed or never signed in)"
    exit 0
fi

CONTENT=$(tr -d '\n\r' < "$CFG" 2>/dev/null)

B64=""
for k in "oauth:tokenCacheV2" "oauth:tokenCache"; do
    B64=$(printf '%s' "$CONTENT" \
        | grep -o "\"$k\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -n 1 | sed 's/.*:[[:space:]]*"//;s/"$//')
    if [ -n "$B64" ]; then
        log "found $k (${#B64} base64 chars)"
        break
    fi
done
if [ -z "$B64" ]; then
    log "config.json has no oauth:tokenCache(V2) entry; keys present:"
    [ -n "$DIAG" ] && printf '%s' "$CONTENT" | grep -o '"[A-Za-z0-9_:.-]*"[[:space:]]*:' \
        | sort -u | sed 's/^/    /' >&2
    exit 0
fi

# Electron safeStorage on Linux prefixes the ciphertext with "v10" (fixed
# Chromium password, no keyring available) or "v11" (password from keyring).
PREFIX=$(printf '%s' "$B64" | base64 -d 2>/dev/null | head -c 3)
case "$PREFIX" in
    v10) PASSWORD="peanuts" ;;
    v11)
        # A keyring lookup can raise a permission prompt (KWallet). If it
        # failed or was refused recently, don't ask again on every poll.
        MARK="${XDG_RUNTIME_DIR:-/tmp}/claude-usage-desktop-keyring-miss-$(id -u)"
        if [ -n "$(find "$MARK" -mmin -30 2>/dev/null)" ] && [ -z "$DIAG" ]; then
            exit 0
        fi
        PASSWORD=""
        if command -v secret-tool >/dev/null 2>&1; then
            for app in Claude claude; do
                PASSWORD=$(timeout 10 secret-tool lookup application "$app" 2>/dev/null)
                [ -n "$PASSWORD" ] && { log "key found via secret-tool (application=$app)"; break; }
            done
        else
            log "secret-tool not installed"
        fi
        if [ -z "$PASSWORD" ] && command -v kwallet-query >/dev/null 2>&1; then
            PASSWORD=$(timeout 20 kwallet-query -f "Claude Keys" -r "Claude Safe Storage" kdewallet 2>/dev/null)
            [ -n "$PASSWORD" ] && log "key found via kwallet-query"
        elif [ -z "$PASSWORD" ]; then
            log "kwallet-query not installed"
        fi
        if [ -z "$PASSWORD" ]; then
            log "could not read the Safe Storage key from the keyring"
            : > "$MARK" 2>/dev/null
            exit 0
        fi
        ;;
    *)
        log "unsupported ciphertext prefix (expected v10 or v11)"
        exit 0
        ;;
esac
log "ciphertext prefix $PREFIX"

# Chromium os_crypt (Linux): AES-128-CBC, IV = 16 spaces, key = PBKDF2-HMAC-SHA1
# (password, salt "saltysalt", 1 iteration, 16 bytes).
HEXPW=$(printf '%s' "$PASSWORD" | od -An -tx1 | tr -d ' \n')
KEY=$(openssl kdf -keylen 16 -kdfopt digest:SHA1 -kdfopt hexpass:"$HEXPW" \
        -kdfopt salt:saltysalt -kdfopt iter:1 PBKDF2 2>/dev/null | tr -d ':\n ')
if [ -z "$KEY" ]; then
    log "openssl kdf failed (openssl >= 3.0 required)"
    exit 0
fi

PLAIN=$(printf '%s' "$B64" | base64 -d 2>/dev/null | tail -c +4 \
    | openssl enc -d -aes-128-cbc -K "$KEY" -iv 20202020202020202020202020202020 2>/dev/null \
    | tr -d '\n\r')
if [ -z "$PLAIN" ]; then
    log "decryption produced no output (wrong key?)"
    exit 0
fi
log "decrypted ${#PLAIN} bytes"

if [ -n "$DIAG" ]; then
    log "field names in the decrypted cache (UUIDs masked):"
    printf '%s' "$PLAIN" | grep -o '"[A-Za-z0-9_:. -]*"[[:space:]]*:' | sort -u \
        | sed -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g;s/^/    /' >&2
fi

# The decrypted JSON may hold several entries (one per client/scope). Split on
# "}" so every access token ends up in a chunk together with its own expiry,
# then prefer entries carrying the user:profile scope (the usage endpoint
# needs it), and among those the one that expires last.
# Output: "<token> <expiresAt ms> <subscriptionType|empty>".
PICK=$(printf '%s' "$PLAIN" | tr '}' '\n' | awk -v DIAGN="$DIAG" '
{
    if (!match($0, /sk-ant-oat[0-9]*-[A-Za-z0-9_-]+/)) next
    tok = substr($0, RSTART, RLENGTH)
    ex = 0
    if (match($0, /"expir[A-Za-z_]*"[ ]*:[ ]*[0-9]+/)) {
        s = substr($0, RSTART, RLENGTH); sub(/.*:[ ]*/, "", s); ex = s + 0
        if (ex > 0 && ex < 100000000000) ex = ex * 1000
    }
    st = ""
    if (match($0, /"subscriptionType"[ ]*:[ ]*"[A-Za-z_]+"/)) {
        s = substr($0, RSTART, RLENGTH); sub(/.*:[ ]*"/, "", s); sub(/"$/, "", s); st = s
    }
    pref = (index($0, "user:profile") > 0) ? 1 : 0
    n++
    if (!found || pref > bestpref || (pref == bestpref && ex > bestex)) {
        found = 1; bestpref = pref; bestex = ex; btok = tok; bst = st
    }
}
END { if (found) printf "%s %.0f %s\n", btok, bestex, bst; if (DIAGN) print n+0 " access token(s) found" > "/dev/stderr" }
')

TOKEN=${PICK%% *}
REST=${PICK#* }
EXPIRES=${REST%% *}
SUB=${REST#* }
[ "$SUB" = "$REST" ] && SUB=""

# A token is a single opaque word; anything else means extraction went wrong.
case "$TOKEN" in
    "" | *[!A-Za-z0-9_.=-]*)
        log "no access token (sk-ant-oat...) in the decrypted cache"
        exit 0
        ;;
esac
case "$EXPIRES" in
    "" | *[!0-9]*) EXPIRES=0 ;;
esac

SUBJSON=""
case "$SUB" in
    "" | *[!A-Za-z_]*) ;;
    *) SUBJSON=",\"subscriptionType\":\"$SUB\"" ;;
esac

log "ok: access token found, expiresAt=$EXPIRES"
printf '{"source":"desktop","claudeAiOauth":{"accessToken":"%s","expiresAt":%s%s}}\n' \
    "$TOKEN" "$EXPIRES" "$SUBJSON"
