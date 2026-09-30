# Install

## Requirements

- ECA. Tested with **0.161.2** (the latest release at the time of writing).
- `bash`, `jq`, and GNU coreutils (`timeout`). `curl` for the optional judge.
- For the installer's JSON schema check: `python3` with the `jsonschema` module (`apt install python3-jsonschema`), **or** Node.js (`npx` fetches `ajv-cli`). You can skip the check with `--no-schema`.

## Install

```bash
git clone https://github.com/brdloush/eca-goal.git
cd eca-goal
./install.sh --dry-run   # show what would change
./install.sh
```

Then restart ECA (or reload the config). Run `/hooks`: you see the four `eca-goal-*` hooks.

The installer:

| What | Where |
|------|-------|
| Symlinks `hooks/eca-goal-*.sh` | `~/.config/eca/hooks/` |
| Symlinks the `commands/` folder | `~/.config/eca/commands/eca-goal` |
| Adds 4 hooks (`eca-goal-claim`, `eca-goal-loop`, `eca-goal-context-compact`, `eca-goal-context-start`) | `~/.config/eca/config.json` → `hooks` |

It respects `$XDG_CONFIG_HOME`. The files are **symlinks** to this checkout, so `git pull` updates them. Use `--copy` if you want copies.

## How config.json is patched

The installer changes only what eca-goal owns, and it checks everything first:

1. **Lint before:** `config.json` must be a valid JSON object. Duplicate keys are reported; if they have different values, the installer stops (a rewrite would drop one of them).
2. **Ownership:** a hook belongs to eca-goal only if its key starts with `eca-goal-` **and** all its actions run an `eca-goal-*.sh` script. If an `eca-goal-*` key does not look like that, the installer stops (use `--force` to take it over).
3. **Upsert:** all eca-goal hooks are removed, then the current ones are added. A second run changes nothing and makes no backup. Old or edited eca-goal hooks are replaced, not duplicated. Other hooks and keys are not touched.
4. **Lint after:** the result must be valid JSON.
5. **Schema check** against [https://eca.dev/config.json](https://eca.dev/config.json), before and after:
   - the eca-goal fragment alone must be fully valid;
   - the patch must not add new schema errors. Errors that were already in your config are shown as warnings, but they do not stop the install. Use `--strict-schema` to require a fully valid config.
6. **Backup:** `config.json.bak.eca-goal.<timestamp>`, written only when something changes.

Note: `jq` writes the file again with 2-space indent. The content and the key order stay the same, but the formatting can change.

## Installer options

```
--uninstall          Remove eca-goal (links, copies and config.json hooks).
--copy               Copy files instead of symlinking them to this repo.
--config-dir DIR     ECA config dir to use.
--dry-run            Show what would change. Write nothing.
--schema-file FILE   Use a local copy of the ECA config JSON schema.
--schema-url URL     Download the schema from URL.
--no-schema          Skip JSON schema validation (JSON lint still runs).
--strict-schema      Fail if config.json is not fully schema-valid after the patch.
--force              Replace conflicting files and eca-goal-* hook keys (backups are kept).
```

## Uninstall

```bash
./install.sh --uninstall
```

This removes the hooks from `config.json` (with a backup) and removes the links. It does not touch the per-project files (`.eca/eca-goal/`, `.eca/rules/eca-goal-lessons.md`).
