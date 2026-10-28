#!/bin/bash

PROGNAME="${0##*/}"
RED='\033[1;31m'    # Red color
GREEN='\033[1;32m'  # Green color
NC='\033[0m'        # No Color

help() {
    local OPTIONS_SPEC="
$PROGNAME verifies that license metadata is self-consistent for every
distributable unit in package/, application/, npm-package/ and npm-package/nuxt-modules/.

For each unit the following must agree:
  1. composer.json \"license\"  ==  dev.json \"license\"   (when dev.json exists)
  2. LICENSE                  ==  the canonical text for that license, byte for byte
  3. README.md                contains exactly one canonical license line
  4. npm packages under a proprietary license are marked \"private\": true
     (only when ORO_LICENSE_REQUIRE_NPM_PRIVATE=1)

$PROGNAME [options]

options:

-h                     | --help                        this help
-b                     | --baseline                    docker images baseline version (accepted for
                                                       interface parity with the other cs checks; this
                                                       check needs no container and ignores it)
-s <source folder>     | --source=<source folder>      application source folder. default is current folder
-r <folder>            | --repositorypath=<folder>     monorepo root. default is auto-detected from --source
"
    echo "$OPTIONS_SPEC"
}

BASELINE_VERSION='master-latest'
APP_SRC="$PWD"
WORKDIR=''

# Reference copies of each canonical license text, relative to the monorepo root.
# Every other LICENSE file must be byte-identical to the reference for its license.
# To change a license text (an annual copyright bump, for example) update every LICENSE file together -
# the references are ordinary files, not a separate source of truth.
REF_OSL="package/commerce/LICENSE"
REF_MIT="package/platform/LICENSE"
REF_PROPRIETARY="package/commerce-enterprise/LICENSE"

# A unit is a top-level directory of each tree. A tree missing on this branch is skipped.
# npm-package/nuxt-modules is listed separately, because npm-package/pnpm-workspace.yaml declares
# nuxt-modules/* as packages.
TREES=(package application npm-package npm-package/nuxt-modules)
# Top-level directories of a tree that are not units. The unit loop skips them, and the trees
# listed in TREES, without a SKIP line, so that SKIP reports only a unit missing its manifest:
#   - npm-package/headless-release holds the .npmrc files for changeset publish.
# Nested manifests are not units either, and the unit loop never reaches them:
#   - npm-package/webpack-config-builder/loader/inject-loader is a copy of the third-party
#     inject-loader package, shipped inside @oroinc/oro-webpack-config-builder. It keeps its
#     author's MIT LICENSE.md.
NOT_UNITS=(npm-package/headless-release)

RETVAL=0
SKIPPED=0

err() {
    echo -e "${RED}FAIL${NC} $1"
    RETVAL=$((RETVAL + 1))
}

# manifest_license <dir> -> raw "license" value from composer.json or package.json
manifest_license() {
    local d="$1" f=""
    [[ -f "$d/composer.json" ]] && f="$d/composer.json"
    [[ -z "$f" && -f "$d/package.json" ]] && f="$d/package.json"
    [[ -z "$f" ]] && return 1
    sed -n 's/.*"license"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1
}

# canonical_id <raw license value> -> OSL-3.0 | MIT | Proprietary
canonical_id() {
    case "$1" in
    proprietary | "SEE LICENSE IN LICENSE") echo "Proprietary" ;;
    OSL-3.0) echo "OSL-3.0" ;;
    MIT) echo "MIT" ;;
    *) return 1 ;;
    esac
}

reference_for() {
    case "$1" in
    OSL-3.0) echo "$REF_OSL" ;;
    MIT) echo "$REF_MIT" ;;
    Proprietary) echo "$REF_PROPRIETARY" ;;
    esac
}

check_unit() {
    local d="$1" rel="${1#"$WORKDIR"/}"
    local raw id ref year line n devlic

    # A directory without a manifest file is not a distributable unit - in a CI workspace
    # it is a build artefact or scratch directory rather than a package.
    # Report it so it stays visible in the log, but do not fail the check on it.
    raw=$(manifest_license "$d") || {
        echo "SKIP $rel: no composer.json or package.json"
        SKIPPED=$((SKIPPED + 1))
        return 1
    }
    if [[ -z "$raw" ]]; then
        err "$rel: manifest declares no \"license\""
        return 0
    fi
    id=$(canonical_id "$raw") || {
        err "$rel: unknown license \"$raw\" (expected OSL-3.0, MIT, proprietary or SEE LICENSE IN LICENSE)"
        return 0
    }

    # 1. dev.json must agree with composer.json
    if [[ -f "$d/dev.json" ]]; then
        devlic=$(sed -n 's/.*"license"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$d/dev.json" | head -1)
        [[ "$devlic" == "$raw" ]] || err "$rel: dev.json says \"$devlic\" but composer.json says \"$raw\""
    fi

    # 2. LICENSE must match the canonical text byte for byte
    if [[ ! -f "$d/LICENSE" ]]; then
        err "$rel: LICENSE file is missing"
        return 0
    fi
    ref=$(reference_for "$id")
    cmp -s "$d/LICENSE" "$WORKDIR/$ref" ||
        err "$rel: LICENSE differs from the canonical $id text ($ref)"

    # 3. README.md must carry exactly one canonical license line, with the LICENSE year
    year=$(sed -n 's/.*(c)[[:space:]]*\(20[0-9][0-9]\).*/\1/p' "$d/LICENSE" | head -1)
    if [[ ! -f "$d/README.md" ]]; then
        err "$rel: README.md is missing"
    else
        line="[$id](LICENSE) Copyright (c) $year Oro Inc."
        n=$(grep -Fxc "$line" "$d/README.md")
        [[ "$n" == "1" ]] || err "$rel: README.md must contain exactly one \"$line\" (found $n)"
    fi

    # 4. proprietary npm packages must not be publishable
    if [[ "$ORO_LICENSE_REQUIRE_NPM_PRIVATE" == "1" && "$rel" == npm-package/* && "$id" == "Proprietary" ]]; then
        grep -q '"private"[[:space:]]*:[[:space:]]*true' "$d/package.json" ||
            err "$rel: proprietary npm package is missing \"private\": true"
    fi
    return 0
}

run() {
    local LOGS total=0 d tree ref rel
    if [[ ! -d "$APP_SRC" ]]; then
        echo "ERROR: Can't find source"
        exit 1
    fi
    APP_SRC=$(realpath "$APP_SRC")
    # Detect workdir (monorepo root) if empty. The cs stage runs this from the application dir
    # (e.g. application/commerce-crm-ee); the units to check live at the monorepo root,
    # two levels up. Same idiom as test_npm_packages.sh / test_phpcs.sh / composer.sh.
    if [[ "X$WORKDIR" == "X" ]]; then
        if [[ "$(basename "$(dirname "$APP_SRC")")" == "application" ]]; then
            WORKDIR="$(dirname "$(dirname "$APP_SRC")")"
        else
            WORKDIR=$APP_SRC
        fi
    fi
    if [[ ! -d "$WORKDIR/package" || ! -d "$WORKDIR/application" ]]; then
        echo "ERROR: Could not locate the monorepo root (package/ + application/); resolved WORKDIR='$WORKDIR'"
        exit 1
    fi

    LOGS="$WORKDIR/var/logs"
    mkdir -p "$LOGS"

    # Unlike the other cs checks this one needs no builder image: it reads files
    # with grep/sed/cmp, which the agent already provides.
    {
        echo "Checking license metadata under $WORKDIR"

        for ref in "$REF_OSL" "$REF_MIT" "$REF_PROPRIETARY"; do
            if [[ ! -f "$WORKDIR/$ref" ]]; then
                echo "ERROR: reference license $ref not found. Update the REF_* paths in $PROGNAME."
                exit 1
            fi
        done

        for tree in "${TREES[@]}"; do
            [[ -d "$WORKDIR/$tree" ]] || continue
            for d in "$WORKDIR/$tree"/*/; do
                [[ -d "$d" ]] || continue
                # Jenkins creates a "<workspace>@tmp" directory alongside every workspace a
                # dir() step enters, so one appears next to the application being built.
                # It is never a unit; skip it quietly to keep the log free of noise on
                # every run. Anything else without a manifest is reported by check_unit.
                [[ "${d%/}" == *@tmp ]] && continue
                rel="${d%/}"
                rel="${rel#"$WORKDIR"/}"
                [[ " ${TREES[*]} ${NOT_UNITS[*]} " == *" $rel "* ]] && continue
                if check_unit "${d%/}"; then
                    total=$((total + 1))
                fi
            done
        done

        echo "Checked $total units ($SKIPPED directory(ies) skipped: no manifest)."

        # A wrong workspace root would find no units and otherwise report success,
        # so treat an empty scan as a failure rather than a pass.
        if [[ $total -eq 0 ]]; then
            echo "ERROR: no units found under $WORKDIR - wrong workspace root?"
            exit 1
        fi

        # The block above runs in a subshell (it is piped into tee), so RETVAL cannot propagate back
        # to the caller - hand it out as the subshell exit status and read it below via PIPESTATUS,
        # the same idiom test_npm_packages.sh uses.
        exit $RETVAL
    } 2>&1 | tee "$LOGS/license_output.log"

    local rc=${PIPESTATUS[0]}
    if [[ $rc -eq 0 ]]; then
        echo -e "${GREEN}License metadata is consistent.${NC}"
    else
        echo -e "${RED}PROBLEM. License metadata check failed ($rc problem(s) found).${NC}"
        exit 1
    fi
}

usage() {
    [ -z "$*" ] || echo "$*"
    echo "Try \`$PROGNAME --help' for more information." >&2
    exit 1
}

OPTIONS=$(getopt -q -n "$PROGNAME" -o hb:s:r: -l help,baseline:,source:,repositorypath: -- "$@")

eval set -- "$OPTIONS"

while :; do
    case "$1" in
    -h | --help)
        set +x
        help
        exit 0
        ;;
    -b | --baseline)
        shift
        if [[ "X$1" != "X" ]]; then
            BASELINE_VERSION="$1"
        fi
        ;;
    -s | --source)
        shift
        if [[ "X$1" != "X" ]]; then
            APP_SRC="$(realpath "$1")"
        fi
        ;;
    -r | --repositorypath)
        shift
        if [[ "X$1" != "X" ]]; then
            WORKDIR="$1"
        fi
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "ERROR: unrecognized option: $1"
        exit 1
        ;;
    esac
    shift
done

run
