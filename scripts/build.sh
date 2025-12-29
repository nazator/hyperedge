#!/usr/bin/env bash

# Nazator Convention Build Script
# - Detects build.json (or uses --pkg)
# - Reads copy[].from and copy[].configs
# - Copies configs from source `from/src/configs/<name>` to target `<dist>/configs/<name>`
# - Copies all `src` contents into `<dist>` (non-destructive; does not remove src)
# - CI-safe: minimal dependencies; uses jq if available, with Node/Python fallback

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

usage() {
	cat <<'USAGE'
Usage: scripts/build.sh [options]

Options:
	--pkg <path>     Package directory containing build.json or package.json (default: current directory)
	--dry-run        Print actions without performing copies
	--help           Show this help

Behavior:
	- dist path is computed as <pkg>/dist based on package location under ./conventions/<org>/<name>
	- copies configs from `from/src/configs/<name>/` into `<dist>/configs/<name>/`
	- copies all `src` contents into `<dist>` after configs copy (configs from `from` take precedence)
USAGE
}

log()   { printf "[build] %s\n" "$*"; }
warn()  { printf "[build][warn] %s\n" "$*"; }
error() { printf "[build][error] %s\n" "$*" >&2; }

DRY_RUN=0
PKG_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--pkg)
			shift
			[[ $# -gt 0 ]] || { error "--pkg requires a path"; exit 2; }
			PKG_DIR="$1"
			shift
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			error "Unknown argument: $1"
			usage
			exit 2
			;;
	esac
done

# Resolve PKG_DIR to absolute
PKG_DIR=$(cd "$PKG_DIR" && pwd)

# Helpers for JSON parsing with fallbacks (jq -> node -> python3)
json_eval() {
	local file="$1" expr="$2"
	if command -v jq >/dev/null 2>&1; then
		jq -r "$expr" "$file"
		return
	fi
	if command -v node >/dev/null 2>&1; then
		node -e "const fs=require('fs');const j=JSON.parse(fs.readFileSync('$file','utf8'));const get=(obj,path)=>path.split('.').reduce((a,k)=>a==null?undefined:a[k],obj);const v=get(j,'$expr'.replace(/\[(\d+)\]/g,'.$1'));if(Array.isArray(v))console.log(JSON.stringify(v));else if(v===undefined){process.exit(1);}else console.log(typeof v==='object'?JSON.stringify(v):String(v));"
		return
	fi
	if command -v python3 >/dev/null 2>&1; then
		python3 - <<PY
import json,sys
from pathlib import Path
f=sys.argv[1]
expr=sys.argv[2]
data=json.loads(Path(f).read_text())
def get(o,p):
	cur=o
	for part in p.replace('[','.').replace(']','').split('.'):
		if part=='':
			continue
		try:
			if part.isdigit():
				cur=cur[int(part)]
			else:
				cur=cur[part]
		except Exception:
			cur=None
			break
	return cur
v=get(data,expr)
if v is None:
	sys.exit(1)
if isinstance(v,(list,dict)):
	print(json.dumps(v))
else:
	print(v)
PY
		"$file" "$expr"
		return
	fi
	error "No JSON parser available (jq/node/python3)."
	exit 3
}

file_exists() { [[ -f "$1" ]]; }
dir_exists()  { [[ -d "$1" ]]; }

# Locate build.json (prefer in PKG_DIR)
BUILD_JSON="$PKG_DIR/build.json"
if ! file_exists "$BUILD_JSON"; then
	if file_exists "$PKG_DIR/package.json"; then
		warn "No build.json in $PKG_DIR; proceeding with defaults from package.json location."
	else
		error "Neither build.json nor package.json found in $PKG_DIR"
		exit 4
	fi
fi

DIST_DIR="$PKG_DIR/dist"
SRC_DIR="$PKG_DIR/src"

log "Package: $PKG_DIR"
log "Dist:    $DIST_DIR"
log "Src:     $SRC_DIR"

mkdir_p() {
	local d="$1"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "mkdir -p $d"
	else
		mkdir -p "$d"
	fi
}

copy_dir() {
	local from="$1" to="$2"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "copy: $from -> $to"
	else
		# Use cp -a for preserving mode/time and include dotfiles
		if dir_exists "$from"; then
			mkdir -p "$to"
			cp -a "$from"/. "$to"/
		else
			warn "Source not found, skipping: $from"
		fi
	fi
}

# 1) Copy entire src/ into dist/
if dir_exists "$SRC_DIR"; then
	mkdir_p "$DIST_DIR"
	copy_dir "$SRC_DIR" "$DIST_DIR"
else
	warn "src directory not found at $SRC_DIR"
fi

# 2) Process build.json copy directives: configs from `from` overrides
if file_exists "$BUILD_JSON"; then
	# Extract copy array length
	# Try to parse as JSON and iterate; fallbacks return JSON strings, so normalize
	# Get whole copy array
	COPY_JSON=$(json_eval "$BUILD_JSON" '.copy' || true)
	if [[ -n "$COPY_JSON" && "$COPY_JSON" != "null" ]]; then
		# Use node/python if available to iterate entries reliably
		if command -v node >/dev/null 2>&1; then
			mapfile -t entries < <(node -e "const j=$COPY_JSON;for(const e of j){console.log(JSON.stringify(e));}")
		elif command -v python3 >/dev/null 2>&1; then
			mapfile -t entries < <(python3 - <<PY
import json
j=json.loads('''$COPY_JSON''')
for e in j:
	print(json.dumps(e))
PY
			)
		else
			# Best-effort with jq if available; already tried above, but handle here
			if command -v jq >/dev/null 2>&1; then
				mapfile -t entries < <(echo "$COPY_JSON" | jq -c '.[]')
			else
				warn "Cannot iterate copy entries (no node/python/jq); skipping configs."
				entries=()
			fi
		fi

		for entry in "${entries[@]}"; do
			# Parse fields
			if command -v jq >/dev/null 2>&1; then
				FROM_REL=$(echo "$entry" | jq -r '.from')
				CFGS_JSON=$(echo "$entry" | jq -c '.configs')
			else
				# Fallback via node/python to extract fields
				if command -v node >/dev/null 2>&1; then
					FROM_REL=$(node -e "const e=$entry;console.log(e.from||'')")
					CFGS_JSON=$(node -e "const e=$entry;console.log(JSON.stringify(e.configs||[]))")
				else
					FROM_REL=$(python3 - <<PY
import json
e=json.loads('''$entry''')
print(e.get('from',''))
PY
					)
					CFGS_JSON=$(python3 - <<PY
import json
e=json.loads('''$entry''')
print(json.dumps(e.get('configs',[])))
PY
					)
				fi
			fi

			if [[ -z "$FROM_REL" ]]; then
				warn "Entry missing 'from'; skipping."
				continue
			fi
			FROM_DIR=$(cd "$PKG_DIR" && realpath -m "$FROM_REL")
			if ! dir_exists "$FROM_DIR"; then
				warn "from path not found: $FROM_DIR"
				continue
			fi

			# Iterate configs
			if command -v jq >/dev/null 2>&1; then
				mapfile -t cfgs < <(echo "$CFGS_JSON" | jq -r '.[]')
			else
				if command -v node >/dev/null 2>&1; then
					mapfile -t cfgs < <(node -e "const a=$CFGS_JSON;for(const x of a)console.log(x)")
				else
					mapfile -t cfgs < <(python3 - <<PY
import json
a=json.loads('''$CFGS_JSON''')
for x in a:
	print(x)
PY
					)
				fi
			fi

			for cfg in "${cfgs[@]}"; do
				SRC_CFG_DIR="$FROM_DIR/src/configs/$cfg"
				DST_CFG_DIR="$DIST_DIR/configs/$cfg"
				log "Config [$cfg]: $SRC_CFG_DIR -> $DST_CFG_DIR"
				mkdir_p "$DST_CFG_DIR"
				copy_dir "$SRC_CFG_DIR" "$DST_CFG_DIR"
			done
		done
	else
		warn "No 'copy' entries in build.json; skipping configs copy."
	fi
else
	warn "build.json not found; skipped configs overlay."
fi

log "Build completed."

