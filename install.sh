#!/bin/sh
# claude-code-freebsd installer
#
# Installs Anthropic's official Linux x64 Claude Code binary on FreeBSD under
# Linuxulator, wrapped with the BUN_JSC_useBBQJIT=0 env var that Anthropic's
# ant-kurt recommends for this configuration in anthropics/claude-code#30640.
#
# This installer does NOT require root. If Linuxulator is not yet enabled on
# the system, it prints the commands you need to run as root and exits. Re-run
# after that setup and it will finish the user-local install.
#
# Source of truth: https://github.com/8ff/claude-code-freebsd

set -eu

REPO="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

# User-local install paths (match Anthropic's Linux layout where possible)
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude"
BIN_DIR="$HOME/.local/bin"
WRAPPER="$BIN_DIR/claude"
BINARY="$DATA_DIR/claude-linux-x64"

# ---------- pretty printers ----------

ESC=$(printf '\033')
c_reset="${ESC}[0m"
c_green="${ESC}[1;32m"
c_yellow="${ESC}[1;33m"
c_red="${ESC}[1;31m"
c_dim="${ESC}[2m"

say()  { printf '%b==>%b %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%b!!!%b %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
fail() { printf '%bxxx%b %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }
cmd()  { printf '    %b$ %s%b\n' "$c_dim" "$*" "$c_reset"; }

# ---------- sanity ----------

[ "$(uname -s)" = "FreeBSD" ] || fail "This installer only supports FreeBSD. Detected: $(uname -s)"
[ "$(uname -m)" = "amd64" ]   || fail "This installer only supports amd64 hosts. Detected: $(uname -m)"

for tool in curl sha256 awk sed; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

# ---------- check Linuxulator state ----------

need_root=0
missing_steps=""

# 1. Linux ABI available? (covers both kmod-loaded and kernel-builtin cases —
#    on FreeBSD 15 linux64 is compiled into GENERIC, so `kldstat -m linux64`
#    returns false even though Linux compat is available)
if ! sysctl -n compat.linux.osrelease >/dev/null 2>&1; then
  need_root=1
  missing_steps="${missing_steps}1"
fi

# 2. linux_base-rl9 package installed? (any linux_base-* variant is OK)
if ! pkg info -q -x '^linux_base-' >/dev/null 2>&1; then
  need_root=1
  missing_steps="${missing_steps}2"
fi

# 3. linprocfs mounted under /compat/linux/proc?
if ! mount | grep -q 'linprocfs.*/compat/linux/proc'; then
  need_root=1
  missing_steps="${missing_steps}3"
fi

# 4. linux service enabled in rc.conf (so it persists)?
if [ "$(sysrc -n linux_enable 2>/dev/null || echo NO)" != "YES" ]; then
  need_root=1
  missing_steps="${missing_steps}4"
fi

if [ "$need_root" = "1" ]; then
  cat >&2 <<'MSG'

===========================================================================
Linuxulator is not fully set up on this FreeBSD host. The Claude Code Linux
binary needs Linuxulator to run. Please enable it with the commands below
(they require root), then re-run this installer.

MSG
  case "$missing_steps" in *1*) cmd "doas kldload linux64" ;; esac
  case "$missing_steps" in *4*) cmd "doas sysrc linux_enable=\"YES\"" ;; esac
  case "$missing_steps" in *2*) cmd "doas pkg install -y linux_base-rl9" ;; esac
  case "$missing_steps" in *3*) cmd "doas service linux start" ;; esac
  cat >&2 <<'MSG'

Then re-run:

MSG
  cmd "curl -fsSL https://raw.githubusercontent.com/8ff/claude-code-freebsd/main/install.sh | sh"
  echo >&2
  exit 1
fi

say "Linuxulator is ready"

# ---------- fetch the latest release manifest ----------

say "Fetching latest Claude Code release metadata from Anthropic CDN"
VERSION="$(curl -fsSL "$REPO/latest")"
[ -n "$VERSION" ] || fail "could not read latest version pointer at $REPO/latest"
say "Latest version: $VERSION"

MANIFEST="$(curl -fsSL "$REPO/$VERSION/manifest.json")"
[ -n "$MANIFEST" ] || fail "could not fetch manifest.json for $VERSION"

# Extract the linux-x64 binary checksum (256-bit hex) without needing jq.
# The platforms.linux-x64 block looks like:
#   "linux-x64": { "binary": "claude", "checksum": "d064b4...", "size": 233507456 }
EXPECTED_SHA="$(
  printf '%s' "$MANIFEST" |
  awk '
    /"linux-x64"/ { in_block=1 }
    in_block && /"checksum"/ {
      match($0, /"checksum"[[:space:]]*:[[:space:]]*"[0-9a-f]+"/)
      s = substr($0, RSTART, RLENGTH)
      sub(/.*"checksum"[[:space:]]*:[[:space:]]*"/, "", s)
      sub(/".*/, "", s)
      print s
      exit
    }'
)"
[ -n "$EXPECTED_SHA" ] || fail "could not parse linux-x64 checksum from manifest"
echo "  expected sha256: $EXPECTED_SHA"

# ---------- check if we already have the right binary on disk ----------

if [ -f "$BINARY" ]; then
  CURRENT_SHA="$(sha256 -q "$BINARY" 2>/dev/null || echo '')"
  if [ "$CURRENT_SHA" = "$EXPECTED_SHA" ]; then
    say "Already on the latest version ($VERSION). Nothing to download."
    SKIP_DOWNLOAD=1
  fi
fi

# ---------- download ----------

if [ "${SKIP_DOWNLOAD:-0}" != "1" ]; then
  say "Downloading linux-x64 Claude Code binary (~230 MB)"
  mkdir -p "$DATA_DIR"
  TMP="$(mktemp -t claude.XXXXXX)"
  trap 'rm -f "$TMP"' EXIT
  curl -fL --progress-bar "$REPO/$VERSION/linux-x64/claude" -o "$TMP"

  say "Verifying sha256"
  ACTUAL_SHA="$(sha256 -q "$TMP")"
  if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    fail "checksum mismatch
  expected: $EXPECTED_SHA
  actual:   $ACTUAL_SHA"
  fi

  chmod +x "$TMP"
  mv "$TMP" "$BINARY"
  trap - EXIT
  say "Installed $BINARY"
fi

# ---------- write the wrapper ----------

say "Writing wrapper script to $WRAPPER"
mkdir -p "$BIN_DIR"
cat > "$WRAPPER" <<EOF
#!/bin/sh
# claude-code-freebsd wrapper
# Runs Anthropic's Linux x64 Claude Code binary under FreeBSD's Linuxulator.
# BUN_JSC_useBBQJIT=0 is required on this path, per anthropics/claude-code#30640.
exec env BUN_JSC_useBBQJIT=0 "$BINARY" "\$@"
EOF
chmod +x "$WRAPPER"

# ---------- PATH hint ----------

PATH_OK=0
for p in $(printf '%s' "$PATH" | tr ':' '\n'); do
  [ "$p" = "$BIN_DIR" ] && PATH_OK=1
done

if [ "$PATH_OK" != "1" ]; then
  if [ -f "$HOME/.profile" ] && grep -q 'HOME/.local/bin' "$HOME/.profile" 2>/dev/null; then
    warn "$BIN_DIR is in ~/.profile but not active in this shell yet."
    warn "Run \`. ~/.profile\` or open a new shell before invoking \`claude\`."
  elif [ -f "$HOME/.profile" ]; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"
    warn "Added $BIN_DIR to ~/.profile."
    warn "Run \`. ~/.profile\` or open a new shell before invoking \`claude\`."
  else
    warn "$BIN_DIR is not on your PATH. Add it manually:"
    cmd 'export PATH="$HOME/.local/bin:$PATH"'
  fi
fi

# ---------- smoke test ----------

say "Smoke test: BUN_JSC_useBBQJIT=0 $BINARY --version"
if env BUN_JSC_useBBQJIT=0 "$BINARY" --version 2>/dev/null; then
  :
else
  warn "--version did not print cleanly. The binary may still work interactively."
fi

# ---------- next steps ----------

cat <<EOF

${c_green}==>${c_reset} Done.

Claude Code $VERSION is installed at:
  $BINARY

Wrapper:
  $WRAPPER

Run it with:
  claude                    # interactive TUI
  claude --version
  claude -p "hi"            # headless mode (needs ANTHROPIC_API_KEY)

To authenticate:
  - API key:    export ANTHROPIC_API_KEY=sk-ant-...
  - Or run \`claude\` interactively and follow the OAuth URL it prints.
    If the URL wraps in your terminal, run \`stty cols 500\` first.

To update later, just re-run the installer:
  curl -fsSL https://raw.githubusercontent.com/8ff/claude-code-freebsd/main/install.sh | sh

To uninstall:
  rm -f $WRAPPER $BINARY
  rmdir $DATA_DIR 2>/dev/null || true

Report bugs / share feedback:
  https://github.com/8ff/claude-code-freebsd/issues
  https://github.com/anthropics/claude-code/issues/30640
EOF
