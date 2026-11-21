#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPES_DIR="${SCRIPT_DIR}/recipes"

# Colors (disabled automatically when not a TTY)
if [[ -t 1 ]] && [[ -z "${NO_COLOR-}" ]]; then
    C_BLUE=$'\033[94m'
    C_GREEN=$'\033[92m'
    C_YELLOW=$'\033[93m'
    C_RED=$'\033[91m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_BOLD="" C_RESET=""
fi

log_info()    { printf '%s[INFO]%s %s\n'    "$C_BLUE"   "$C_RESET" "$*"; }
log_ok()      { printf '%s[SUCCESS]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()    { printf '%s[WARN]%s %s\n'    "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error()   { printf '%s[ERROR]%s %s\n'   "$C_RED"    "$C_RESET" "$*" >&2; }

usage() {
    cat <<EOF
${C_BOLD}Usage:${C_RESET}
  ./generate.sh [OPTIONS] <package> <version>

${C_BOLD}Arguments:${C_RESET}
  <package>               Package directory name inside recipes/ (e.g. pydantic-core, scipy)
  <version>               Target version to create (e.g. 2.50.6, 1.18.2)

${C_BOLD}Options:${C_RESET}
  -e, --edit              Open generated recipe.yaml in nano (or --editor) after creation
      --editor <cmd>      Editor command to use with --edit (default: nano)
  -f, --force             Overwrite target version directory if it already exists
  -s, --from <version>    Use a specific existing version as template instead of closest match
      --new               Create a starter recipe.yaml if package has no existing versions
      --git-commit-and-push
                          Stage, commit ("feat(<pkg>): v<ver>"), and push to git
      --dry-run           Show what would be done without creating/modifying files or pushing
  -h, --help              Show this help message and exit

${C_BOLD}Examples:${C_RESET}
  ./generate.sh pydantic-core 2.50.6
  ./generate.sh scipy 1.18.2 --edit
  ./generate.sh numpy 2.4.5 --git-commit-and-push
  ./generate.sh maturin 1.16.1 --from 1.16.0 --edit --git-commit-and-push
  ./generate.sh httpx 0.28.1 --new --edit
  ./generate.sh scipy 1.17.9 --dry-run
EOF
}

validate_segment() {
    local value="$1" label="$2"
    if [[ -z "$value" ]] || [[ "$value" == *".."* ]] || [[ "$value" == *"/"* ]] || [[ "$value" == *"\\"* ]]; then
        log_error "Invalid ${label}: '${value}'"
        exit 2
    fi
    if [[ ! "$value" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        log_error "Invalid characters in ${label}: '${value}'"
        exit 2
    fi
}

find_closest_version() {
    local target="$1"
    shift
    printf '%s\n' "$@" | awk -v target="$target" '
    function parse_ver(ver, out_arr,    n, i, seg, is_pre, parts) {
        is_pre = (ver ~ /[A-Za-z]/) ? 1 : 0
        n = split(ver, parts, /[._+-]/)
        for (i = 1; i <= 8; i++) {
            if (i <= n) {
                seg = parts[i]
                sub(/[^0-9].*$/, "", seg)
                out_arr[i] = (seg == "") ? 0 : (seg + 0)
            } else {
                out_arr[i] = 0
            }
        }
        out_arr[9] = is_pre
    }
    function abs_val(x) { return x < 0 ? -x : x }
    function is_better(c_dist, c_ver, b_dist, b_ver,    i) {
        for (i = 1; i <= 8; i++) {
            if (c_dist[i] < b_dist[i]) return 1
            if (c_dist[i] > b_dist[i]) return 0
        }
        if (c_ver[9] < b_ver[9]) return 1
        if (c_ver[9] > b_ver[9]) return 0
        for (i = 1; i <= 8; i++) {
            if (c_ver[i] > b_ver[i]) return 1
            if (c_ver[i] < b_ver[i]) return 0
        }
        return 0
    }
    BEGIN {
        parse_ver(target, t_arr)
        has_best = 0
    }
    NF > 0 {
        cand = $0
        parse_ver(cand, c_arr)
        for (i = 1; i <= 8; i++) {
            c_dist[i] = abs_val(t_arr[i] - c_arr[i])
        }
        if (!has_best || is_better(c_dist, c_arr, b_dist, b_arr)) {
            has_best = 1
            best_name = cand
            for (i = 1; i <= 9; i++) {
                b_arr[i] = c_arr[i]
                if (i <= 8) b_dist[i] = c_dist[i]
            }
        }
    }
    END {
        if (has_best) print best_name
    }'
}

update_recipe_yaml() {
    local src_file="$1" dst_file="$2" new_ver="$3"
    awk -v new_ver="$new_ver" '
    BEGIN { in_meta = 0 }
    /^[^[:space:]#]/ {
        in_meta = ($0 ~ /^metadata:[[:space:]]*(#.*)?$/) ? 1 : 0
    }
    in_meta && /^[[:space:]]+version:[[:space:]]*/ {
        match($0, /^[[:space:]]+version:[[:space:]]*/)
        prefix = substr($0, 1, RLENGTH)
        rest = substr($0, RLENGTH + 1)
        comment = ""
        if (match(rest, /[[:space:]]+#.*$/)) {
            comment = substr(rest, RSTART)
        }
        print prefix "\"" new_ver "\"" comment
        next
    }
    in_meta && /^[[:space:]]+download_version:[[:space:]]*/ {
        match($0, /^[[:space:]]+download_version:[[:space:]]*/)
        prefix = substr($0, 1, RLENGTH)
        rest = substr($0, RLENGTH + 1)
        comment = ""
        if (match(rest, /[[:space:]]+#.*$/)) {
            comment = substr(rest, RSTART)
        }
        print prefix "\"" new_ver "\"" comment
        next
    }
    { print }' "$src_file" > "$dst_file"
}

# --- Argument Parsing ---
EDIT=0
FORCE=0
CREATE_NEW=0
DRY_RUN=0
GIT_COMMIT_AND_PUSH=0
FROM_VERSION=""
EDITOR_CMD="nano"
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -e|--edit)
            EDIT=1
            shift
            ;;
        --editor)
            if [[ $# -lt 2 ]]; then
                log_error "Option $1 requires an editor command."
                exit 2
            fi
            EDITOR_CMD="$2"
            shift 2
            ;;
        --editor=*)
            EDITOR_CMD="${1#*=}"
            shift
            ;;
        -f|--force)
            FORCE=1
            shift
            ;;
        --new)
            CREATE_NEW=1
            shift
            ;;
        --git-commit-and-push)
            GIT_COMMIT_AND_PUSH=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -s|--from)
            if [[ $# -lt 2 ]]; then
                log_error "Option $1 requires a version argument."
                exit 2
            fi
            FROM_VERSION="$2"
            shift 2
            ;;
        --from=*)
            FROM_VERSION="${1#*=}"
            shift
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            log_error "Unknown option: $1"
            usage >&2
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
    log_error "Expected 2 positional arguments: <package> <version>"
    usage >&2
    exit 2
fi

PACKAGE="${POSITIONAL[0]}"
TARGET_VERSION="${POSITIONAL[1]}"

validate_segment "$PACKAGE" "package name"
validate_segment "$TARGET_VERSION" "version"
if [[ -n "$FROM_VERSION" ]]; then
    validate_segment "$FROM_VERSION" "source version"
fi

if [[ ! -d "$RECIPES_DIR" ]]; then
    log_error "Recipes directory not found: ${RECIPES_DIR}"
    exit 1
fi

PKG_DIR="${RECIPES_DIR}/${PACKAGE}"

# Try normalizing '-' / '_' if exact folder doesn't exist
if [[ ! -d "$PKG_DIR" ]]; then
    ALT_PKG=""
    if [[ "$PACKAGE" == *"_"* ]] && [[ -d "${RECIPES_DIR}/${PACKAGE//_/-}" ]]; then
        ALT_PKG="${PACKAGE//_/-}"
    elif [[ "$PACKAGE" == *"-"* ]] && [[ -d "${RECIPES_DIR}/${PACKAGE//-/_}" ]]; then
        ALT_PKG="${PACKAGE//-/_}"
    fi
    if [[ -n "$ALT_PKG" ]]; then
        log_warn "Folder '${PACKAGE}' not found, using '${ALT_PKG}' instead."
        PACKAGE="$ALT_PKG"
        PKG_DIR="${RECIPES_DIR}/${PACKAGE}"
    fi
fi

REL_TARGET="recipes/${PACKAGE}/${TARGET_VERSION}"
TARGET_DIR="${PKG_DIR}/${TARGET_VERSION}"
TARGET_RECIPE="${TARGET_DIR}/recipe.yaml"

if [[ -e "$TARGET_DIR" ]] && [[ "$FORCE" -eq 0 ]]; then
    log_error "Target already exists: ${REL_TARGET} (use --force to overwrite)"
    exit 1
fi

# Collect existing versions
EXISTING_VERSIONS=()
if [[ -d "$PKG_DIR" ]]; then
    for d in "$PKG_DIR"/*/; do
        [[ -d "$d" ]] || continue
        ver_name="$(basename "$d")"
        if [[ -f "${d}recipe.yaml" ]]; then
            EXISTING_VERSIONS+=("$ver_name")
        fi
    done
fi

if [[ ${#EXISTING_VERSIONS[@]} -eq 0 ]]; then
    if [[ "$CREATE_NEW" -eq 0 ]]; then
        log_error "No existing recipes found for '${PACKAGE}' in recipes/${PACKAGE}."
        log_info "Pass --new to scaffold a blank recipe.yaml."
        exit 1
    fi

    log_info "Creating new package recipe: ${REL_TARGET}/recipe.yaml"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[dry-run] Would create ${TARGET_RECIPE}"
    else
        [[ "$FORCE" -eq 1 ]] && rm -rf "$TARGET_DIR"
        mkdir -p "$TARGET_DIR"
        cat > "$TARGET_RECIPE" <<EOF
metadata:
  name: "${PACKAGE//-/_}"
  version: "${TARGET_VERSION}"
  download_version: "${TARGET_VERSION}"

build:
  system_dependencies: []
  env: {}
  patches: []
EOF
        log_ok "Created ${TARGET_RECIPE}"
    fi
else
    if [[ -n "$FROM_VERSION" ]]; then
        SOURCE_VERSION="$FROM_VERSION"
        if [[ ! -f "${PKG_DIR}/${SOURCE_VERSION}/recipe.yaml" ]]; then
            log_error "Specified source recipe not found: recipes/${PACKAGE}/${SOURCE_VERSION}/recipe.yaml"
            exit 1
        fi
    else
        SOURCE_VERSION="$(find_closest_version "$TARGET_VERSION" "${EXISTING_VERSIONS[@]}")"
    fi

    if [[ "$SOURCE_VERSION" == "$TARGET_VERSION" ]]; then
        log_error "Source and target versions are identical (${TARGET_VERSION})."
        exit 1
    fi

    SOURCE_DIR="${PKG_DIR}/${SOURCE_VERSION}"
    log_info "Package: ${PACKAGE} | Closest template: ${SOURCE_VERSION} -> Target: ${TARGET_VERSION}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[dry-run] Would copy ${SOURCE_DIR} -> ${TARGET_DIR}"
        log_info "[dry-run] Would set version & download_version to \"${TARGET_VERSION}\""
    else
        if [[ -e "$TARGET_DIR" ]] && [[ "$FORCE" -eq 1 ]]; then
            rm -rf "$TARGET_DIR"
        fi

        cp -R "$SOURCE_DIR" "$TARGET_DIR"
        tmp_yaml="$(mktemp)"
        update_recipe_yaml "${SOURCE_DIR}/recipe.yaml" "$tmp_yaml" "$TARGET_VERSION"
        mv "$tmp_yaml" "$TARGET_RECIPE"

        log_ok "Generated ${REL_TARGET}/recipe.yaml"

        if [[ -d "${TARGET_DIR}/patches" ]] && [[ -n "$(ls -A "${TARGET_DIR}/patches" 2>/dev/null || true)" ]]; then
            log_warn "Patches were copied from ${SOURCE_VERSION}. Verify they still apply cleanly to ${TARGET_VERSION}!"
        fi
    fi
fi

# --- Optional Edit ---
if [[ "$EDIT" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[dry-run] Would open ${TARGET_RECIPE} in '${EDITOR_CMD}'"
    else
        if ! command -v "$EDITOR_CMD" >/dev/null 2>&1; then
            log_error "Editor '${EDITOR_CMD}' not found in PATH."
            exit 1
        fi
        "$EDITOR_CMD" "$TARGET_RECIPE"
    fi
fi

# --- Optional Git Commit & Push ---
if [[ "$GIT_COMMIT_AND_PUSH" -eq 1 ]]; then
    COMMIT_MSG="feat(${PACKAGE}): v${TARGET_VERSION}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[dry-run] Would run: git add -- \"${REL_TARGET}\" && git commit -m \"${COMMIT_MSG}\" -- \"${REL_TARGET}\" && git push"
        exit 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_error "'git' not found in PATH."
        exit 1
    fi
    if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_error "Directory is not a git repository: ${SCRIPT_DIR}"
        exit 1
    fi

    log_info "Staging ${REL_TARGET}..."
    git -C "$SCRIPT_DIR" add -- "$REL_TARGET"

    if git -C "$SCRIPT_DIR" diff --cached --quiet -- "$REL_TARGET"; then
        log_warn "No changes to commit in ${REL_TARGET}. Skipping commit and push."
    else
        log_info "Committing: ${COMMIT_MSG}"
        git -C "$SCRIPT_DIR" commit -m "$COMMIT_MSG" -- "$REL_TARGET"
        log_info "Pushing to remote..."
        git -C "$SCRIPT_DIR" push
        log_ok "Committed and pushed ${REL_TARGET}"
    fi
fi