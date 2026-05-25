# easy_tools — repo-specific guidance

## Script name

Actual script is `easy_fclone.sh`, not `easy_foren.bash` as the README says. The README docstring is outdated.

## Language

All comments, error messages, and docs are in **Portuguese** (Brazilian). CLI output (`echo`, `msg_error`) is also Portuguese.

## Running the tool

```bash
sudo ./easy_fclone.sh -s /dev/sdX -d /path/to/dest -S 1G -B 32M -n case_name [-N notes]
# Restore mode (no root needed for file I/O):
./easy_fclone.sh -r -s /path/to/segments -d /output.img
```

Requires **root** for device access (clone mode). Dependencies: `dd`, `openssl`, `uuidgen`/`dbus-uuidgen`, `lsblk`, `fdisk`, `numfmt` (coreutils). Bash 4.0+.

## Project structure

Only one source file. No tests, no build, no CI.

## Architecture

- `easy_fclone.sh` — standalone Bash script. Entrypoint is the bottom of the file (post-function calls at lines ~396–399).
- `create_segments` is the main orchestrator. Internally calls `get_vol_info` (no longer a global, returns pipe-delimited string), `write_head`, `progress_bar`, `dd`.
- Version is tracked in script header comments (`# Version x.y.z`), parsed by `get_version` via `grep` on `$0`.
- Segments are binary dumps with a pipe-delimited header **appended** to each segment file after dd writes the data.
- Hash algorithm is SHA3–256 (`openssl dgst -sha3-256`).
- Size parsing uses `parse_size` (binary: K=1024, M=1024^2, etc. — same as dd behavior).
- Volume hash is computed **in parallel** via background `openssl dgst -sha3-256` while the segment `dd` reads the source (populates page cache; hash reads from cache).
- Headers are deferred: dd writes data first, then headers are appended in a second pass after the hash is collected.
- `conv=sync` removed — last segment count is recalculated per iteration to avoid zero-padding.
- `get_vol_hash` / `get_calculated_count` removed — inlined or replaced.
- Restore mode (`-r`): reads segment directory, iterates `.bin` files sorted by segment number, validates per-segment HEADER_HASH (integrity) and HASH_SEGMENT (data), cross-checks HASH_VOLUME on last segment. Uses `tee -a` for single-pass append + hash of output data.
- `parse_header` finds header markers via `grep -a -b -o -P` on the raw dd pipe (avoids Bash null-byte stripping in `$(...)`). Never store binary tail in a Bash variable.
- Header structure: pipe-delimited key:value fields appended to each segment file after the binary data. Last field is `|HEADER_HASH:<sha3-256>` covering everything from `|MODEL:` up to (exclusive) `|HEADER_HASH:`.

## Conventions

- Script uses `set -euo pipefail`.
- All function-local variables declared with `local`.
- Error codes: 1 (param/validation), 2 (missing dep), 3 (hash failure), 6 (dd failure), 7 (disk space).
- Functions communicate results via `echo`, not global variables (refactored in v0.4.0).

## CodeGraph

This repo has a `.codegraph/` index initialized. Use `codegraph_*` tools for structural queries.
