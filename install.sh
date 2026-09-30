#!/usr/bin/env bash
# eca-goal installer: links the hooks and commands into the ECA config dir and
# upserts the eca-goal hooks into config.json.
#
# config.json is patched safely:
#   - JSON lint before and after (jq)
#   - JSON schema validation before and after (https://eca.dev/config.json);
#     the patch must not add schema errors, and the eca-goal fragment alone
#     must be fully valid
#   - upsert: only hook keys named "eca-goal-*" that point to eca-goal-*.sh
#     scripts are replaced or removed; anything else is left alone
#   - a timestamped backup is written before every change
set -euo pipefail

REPO=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/eca
SCHEMA_URL=https://eca.dev/config.json
SCHEMA_FILE=""
MODE=install      # install | uninstall
LINK_MODE=symlink # symlink | copy
DRY_RUN=0
SCHEMA_CHECK=1
STRICT_SCHEMA=0
FORCE=0

usage() {
  cat <<EOF
Usage: ./install.sh [options]

Installs eca-goal into the ECA config dir (default: $CONFIG_DIR).

Options:
  --uninstall          Remove eca-goal (links, copies and config.json hooks).
  --copy               Copy files instead of symlinking them to this repo.
  --config-dir DIR     ECA config dir to use.
  --dry-run            Show what would change. Write nothing.
  --schema-file FILE   Use a local copy of the ECA config JSON schema.
  --schema-url URL     Download the schema from URL (default: $SCHEMA_URL).
  --no-schema          Skip JSON schema validation (JSON lint still runs).
  --strict-schema      Fail if config.json is not fully schema-valid after
                       the patch (default: fail only on NEW errors).
  --force              Replace conflicting files and "eca-goal-*" hook keys
                       that do not look like eca-goal (backups are kept).
  -h, --help           Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) MODE=uninstall ;;
    --copy) LINK_MODE=copy ;;
    --config-dir) CONFIG_DIR=${2:?--config-dir needs a value}; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --schema-file) SCHEMA_FILE=${2:?--schema-file needs a value}; shift ;;
    --schema-url) SCHEMA_URL=${2:?--schema-url needs a value}; shift ;;
    --no-schema) SCHEMA_CHECK=0 ;;
    --strict-schema) STRICT_SCHEMA=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; else B=; R=; G=; Y=; N=; fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %sok%s   %s\n' "$G" "$N" "$*"; }
warn() { printf '  %swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then say "  (dry-run) $*"; else "$@"; fi; }

command -v jq >/dev/null || die "jq is required (the hooks need it too)."
[ "$MODE" = uninstall ] || command -v curl >/dev/null || warn "curl not found: judge: local will not work."

CONFIG_DIR=${CONFIG_DIR/#\~/$HOME}
CONFIG_JSON="$CONFIG_DIR/config.json"
HOOKS_DIR="$CONFIG_DIR/hooks"
COMMANDS_LINK="$CONFIG_DIR/commands/eca-goal"
STAMP=$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

HOOK_FILES=(eca-goal-loop.sh eca-goal-context.sh eca-goal-claim.sh eca-goal-lib.sh)
# jq predicate: a hook entry that belongs to eca-goal
OWNED_JQ='(.key | startswith("eca-goal-")) and ([.value | objects | .actions | arrays | .[]] | length > 0 and all(.[]; (objects | .file | strings) // "" | test("(^|/)eca-goal-[^/]*\\.sh$")))'

# ---------------------------------------------------------------- JSON schema

VALIDATOR=""
pick_validator() {
  if python3 -c 'import jsonschema' 2>/dev/null; then VALIDATOR=python
  elif command -v npx >/dev/null; then VALIDATOR=ajv
  else die "No JSON schema validator found. Install python3-jsonschema (or Node.js for npx ajv-cli), or use --no-schema."
  fi
}

fetch_schema() {
  if [ -n "$SCHEMA_FILE" ]; then
    [ -f "$SCHEMA_FILE" ] || die "Schema file not found: $SCHEMA_FILE"
    cp "$SCHEMA_FILE" "$WORK/schema.json"
  else
    curl -fsSL --max-time 30 "$SCHEMA_URL" -o "$WORK/schema.json" \
      || die "Cannot download the schema from $SCHEMA_URL. Use --schema-file FILE or --no-schema."
  fi
  jq -e 'type == "object"' "$WORK/schema.json" >/dev/null 2>&1 || die "The schema is not valid JSON."
}

# validate FILE -> prints one line per error: "<instancePath>\t<keyword>\t<message>"
# exit 0 = ran (valid or not), exit 1 = the validator itself failed
validate() {
  local file=$1
  case "$VALIDATOR" in
    python)
      python3 - "$WORK/schema.json" "$file" <<'PY'
import json, sys
from jsonschema import Draft7Validator
schema = json.load(open(sys.argv[1])); data = json.load(open(sys.argv[2]))
def ptr(path):
    return "".join("/" + str(p).replace("~", "~0").replace("/", "~1") for p in path)
for e in sorted(Draft7Validator(schema).iter_errors(data), key=lambda e: ptr(e.absolute_path)):
    print(f"{ptr(e.absolute_path)}\t{e.validator}\t{e.message}")
PY
      ;;
    ajv)
      local err rc=0
      err=$(npx --yes -p ajv-cli@5 -p ajv-formats@2 ajv validate --spec=draft7 --strict=false \
              --all-errors -c ajv-formats -s "$WORK/schema.json" -d "$file" --errors=json 2>&1 >/dev/null) || rc=$?
      [ "$rc" = 0 ] && return 0 # "<file> valid" goes to stdout
      grep -q ' invalid$' <<<"$err" || { printf '%s\n' "$err" >&2; return 1; }
      awk 'f || /^\[/ { f = 1; print }' <<<"$err" \
        | jq -r '.[] | [.instancePath, .keyword, .message] | @tsv' | sort -u
      ;;
  esac
}

# duplicate_keys FILE -> prints "<path>\t<same|different>" for each duplicate object key.
# jq keeps only the last duplicate, so a rewrite would drop the others silently.
duplicate_keys() {
  if command -v python3 >/dev/null; then
    python3 - "$1" <<'PY'
import json, sys
def hook(pairs):
    seen = {}
    for k, v in pairs:
        if k in seen:
            print(f"{k}\t{'same' if seen[k] == v else 'different'}")
        seen[k] = v
    return dict(pairs)
json.load(open(sys.argv[1]), object_pairs_hook=hook)
PY
  else
    # fallback: repeated leaf paths (misses duplicates whose values do not overlap)
    jq -c --stream 'select(length == 2) | .[0]' "$1" | LC_ALL=C sort | uniq -d | sed 's/$/\tunknown/'
  fi
}

# lint FILE LABEL -> valid JSON object, and no duplicate keys with different values
lint() {
  local file=$1 label=$2 dups
  jq -e 'type == "object"' "$file" >/dev/null 2>"$WORK/lint.err" \
    || die "config.json is not a valid JSON object ($label): $(cat "$WORK/lint.err")"
  dups=$(duplicate_keys "$file")
  if [ -n "$dups" ]; then
    warn "config.json has duplicate keys ($label). Only the last one is kept on rewrite:"
    sed 's/^/         /' <<<"$dups" >&2
    if grep -qv $'\tsame$' <<<"$dups" && [ "$FORCE" = 0 ]; then
      die "duplicate keys with different (or unknown) values would lose data. Fix config.json by hand, or use --force."
    fi
  fi
  ok "lint $label: valid JSON"
}

# keys used to compare error sets: "<instancePath>\t<keyword>"
error_keys() { cut -f1,2 "$1" | LC_ALL=C sort -u; }

# ---------------------------------------------------------------- files

# is_ours PATH -> 0 if PATH is an eca-goal link or copy (safe to replace/remove)
is_ours() {
  local p=$1 f
  if [ -L "$p" ]; then
    case "$(readlink "$p")" in "$REPO"/*|*/eca-goal*|*eca-goal-*.sh) return 0 ;; esac
    [ -e "$p" ] || return 0 # dangling link with our name
    grep -qs 'eca-goal' "$(readlink -f "$p")" && return 0
    return 1
  elif [ -d "$p" ]; then
    for f in "$p"/*; do [ -e "$f" ] || continue; grep -qs 'eca-goal:' "$f" || return 1; done
    return 0
  elif [ -f "$p" ]; then
    head -n 3 "$p" | grep -q 'eca-goal:'
  else
    return 1
  fi
}

# place SRC DEST -> symlink or copy SRC to DEST, replacing an earlier eca-goal install
place() {
  local src=$1 dest=$2
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ -L "$dest" ] && [ "$LINK_MODE" = symlink ] && [ "$(readlink "$dest")" = "$src" ]; then
      ok "$dest (already linked)"; return 0
    fi
    if ! is_ours "$dest"; then
      [ "$FORCE" = 1 ] || die "$dest exists and is not from eca-goal. Move it away or use --force."
      run mv "$dest" "$dest.bak.eca-goal.$STAMP"; warn "moved foreign $dest to $dest.bak.eca-goal.$STAMP"
    else
      run rm -rf "$dest"
    fi
  fi
  if [ "$LINK_MODE" = symlink ]; then run ln -s "$src" "$dest"; else run cp -R "$src" "$dest"; fi
  ok "$dest -> $src ($LINK_MODE)"
}

remove_ours() {
  local dest=$1
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if is_ours "$dest"; then run rm -rf "$dest"; ok "removed $dest"
    else warn "$dest is not from eca-goal, left alone"; fi
  fi
}

# ---------------------------------------------------------------- config.json

patch_config() {
  step "Patching $CONFIG_JSON"
  local before="$WORK/before.json" after="$WORK/after.json" fragment="$WORK/fragment.json"

  # 1) lint before
  if [ -f "$CONFIG_JSON" ]; then
    cp "$CONFIG_JSON" "$before"
    lint "$before" before
  else
    echo '{}' >"$before"
    ok "no config.json yet, starting from {}"
  fi

  # 2) ownership: refuse to touch "eca-goal-*" keys that are not ours
  local foreign
  foreign=$(jq -r "(.hooks // {}) | to_entries[] | select((.key | startswith(\"eca-goal-\")) and (($OWNED_JQ) | not)) | .key" "$before")
  if [ -n "$foreign" ]; then
    [ "$FORCE" = 1 ] || die "hooks in config.json use the eca-goal- prefix but do not point to eca-goal scripts: $(echo $foreign). Rename them or use --force."
    warn "--force: replacing foreign hook keys: $(echo $foreign)"
  fi
  local strays
  strays=$(jq -r "(.hooks // {}) | to_entries[] | select((.key | startswith(\"eca-goal-\") | not) and ([.value | objects | .actions | arrays | .[] | objects | .file | strings | test(\"(^|/)eca-goal-[^/]*\\\\.sh$\")] | any)) | .key" "$before")
  [ -z "$strays" ] || warn "other hooks also run eca-goal scripts and will run twice: $(echo $strays). Remove them by hand."

  # 3) build the patched config (upsert: drop every eca-goal-* key, then add the current ones)
  if [ "$MODE" = install ]; then
    sed "s|@HOOKS_DIR@|$HOOKS_DIR|g" "$REPO/config/eca-goal.hooks.json" >"$fragment"
    jq -e 'type == "object"' "$fragment" >/dev/null || die "config/eca-goal.hooks.json is broken."
    jq --indent 2 --slurpfile frag "$fragment" \
      '.hooks = (((.hooks // {}) | with_entries(select(.key | startswith("eca-goal-") | not))) + $frag[0])' \
      "$before" >"$after"
  else
    jq --indent 2 \
      '(.hooks // {}) as $h
       | if has("hooks") then .hooks = ($h | with_entries(select(.key | startswith("eca-goal-") | not))) else . end
       | if .hooks == {} then del(.hooks) else . end' \
      "$before" >"$after"
  fi

  # 4) lint after
  lint "$after" after

  # 5) schema before / after
  if [ "$SCHEMA_CHECK" = 1 ]; then
    pick_validator; fetch_schema
    say "  schema: $([ -n "$SCHEMA_FILE" ] && echo "$SCHEMA_FILE" || echo "$SCHEMA_URL") (validator: $VALIDATOR)"
    if [ "$MODE" = install ]; then
      jq -n --slurpfile frag "$fragment" '{hooks: $frag[0]}' >"$WORK/frag-only.json"
      validate "$WORK/frag-only.json" >"$WORK/frag.err" || die "schema validator failed."
      [ ! -s "$WORK/frag.err" ] || { cat "$WORK/frag.err" >&2; die "the eca-goal fragment does not match the ECA schema. Nothing written."; }
      ok "schema: eca-goal fragment is valid"
    fi
    validate "$before" >"$WORK/before.err" || die "schema validator failed."
    validate "$after" >"$WORK/after.err" || die "schema validator failed."
    local nb na new
    nb=$(wc -l <"$WORK/before.err"); na=$(wc -l <"$WORK/after.err")
    new=$(LC_ALL=C comm -13 <(error_keys "$WORK/before.err") <(error_keys "$WORK/after.err"))
    if [ "$nb" -gt 0 ]; then
      warn "config.json already had $nb schema error(s) before the patch (not from eca-goal):"
      sed 's/^/         /' "$WORK/before.err" >&2
    else
      ok "schema before: valid"
    fi
    [ -z "$new" ] || { say "$new" >&2; die "the patch would add schema errors (see above). Nothing written."; }
    if [ "$na" -gt 0 ] && [ "$STRICT_SCHEMA" = 1 ]; then die "--strict-schema: config.json has $na schema error(s) after the patch. Nothing written."; fi
    ok "schema after: no new errors ($na total)"
  else
    warn "schema validation skipped (--no-schema)"
  fi

  # 6) write (with backup), only if something changed
  if [ -f "$CONFIG_JSON" ] && cmp -s <(jq -S . "$before") <(jq -S . "$after"); then
    ok "config.json already up to date, not written"
    return 0
  fi
  if [ -f "$CONFIG_JSON" ] && ! cmp -s "$before" <(jq --indent 2 . "$before"); then
    warn "jq rewrites config.json with 2-space indent; formatting may change (content and key order are kept)"
  fi
  diff -u --label "config.json (before)" --label "config.json (after)" "$before" "$after" | sed 's/^/    /' || true
  if [ "$DRY_RUN" = 1 ]; then say "  (dry-run) config.json not written"; return 0; fi
  mkdir -p "$CONFIG_DIR"
  if [ -f "$CONFIG_JSON" ]; then
    cp -p "$CONFIG_JSON" "$CONFIG_JSON.bak.eca-goal.$STAMP"
    ok "backup: $CONFIG_JSON.bak.eca-goal.$STAMP"
  fi
  cat "$after" >"$CONFIG_JSON" # keeps the inode, so a symlinked config.json stays a symlink
  jq -e . "$CONFIG_JSON" >/dev/null || die "config.json broke on write. Restore it from the backup."
  ok "config.json written"
}

# ---------------------------------------------------------------- main

say "${B}eca-goal${N} $MODE -> $CONFIG_DIR"
[ "$DRY_RUN" = 1 ] && say "(dry-run: nothing is written)"

if [ "$MODE" = install ]; then
  for f in "${HOOK_FILES[@]}"; do [ -f "$REPO/hooks/$f" ] || die "missing $REPO/hooks/$f"; done
  # preflight: fail on foreign files before anything is changed
  if [ "$FORCE" = 0 ]; then
    for dest in "${HOOK_FILES[@]/#/$HOOKS_DIR/}" "$COMMANDS_LINK"; do
      if { [ -e "$dest" ] || [ -L "$dest" ]; } && ! is_ours "$dest"; then
        die "$dest exists and is not from eca-goal. Move it away or use --force."
      fi
    done
  fi
  patch_config
  step "Hooks"
  run mkdir -p "$HOOKS_DIR"
  run chmod +x "$REPO"/hooks/*.sh
  for f in "${HOOK_FILES[@]}"; do place "$REPO/hooks/$f" "$HOOKS_DIR/$f"; done
  step "Commands (/goal, /goal-pause, /goal-resume, /goal-status)"
  run mkdir -p "$CONFIG_DIR/commands"
  place "$REPO/commands" "$COMMANDS_LINK"
  step "Done"
  say "Restart ECA (or reload the config), then run /hooks to see the eca-goal hooks."
  say "Start a goal with: /goal <what you want>"
else
  patch_config
  step "Files"
  for f in "${HOOK_FILES[@]}"; do remove_ours "$HOOKS_DIR/$f"; done
  remove_ours "$COMMANDS_LINK"
  step "Done"
  say "Per-project files (.eca/eca-goal/, .eca/rules/eca-goal-lessons.md) are left alone."
fi
