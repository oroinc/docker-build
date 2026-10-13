#!/bin/bash

PROGNAME="${0##*/}"
RED='\033[1;31m'
GREEN='\033[1;32m'
NC='\033[0m'

help() {
    local OPTIONS_SPEC="
$PROGNAME runs the commerce-ui unit, browser and Storybook tests with coverage
inside the Playwright image. The Storybook tests include the axe accessibility checks
of every story.

$PROGNAME [options]

options:

-h                     | --help                        this help
-b                     | --baseline                    docker images baseline version
-s                     | --source                      application source folder. default is current folder
-r <folder>            | --repositorypath=<folder>     monorepo root. default is auto-detected from --source
"
    echo "$OPTIONS_SPEC"
}

PLAYWRIGHT_IMAGE=${PLAYWRIGHT_IMAGE-mcr.microsoft.com/playwright:v1.63.0-noble}
APP_SRC="$PWD"
WORKDIR=''
ISOLATED=''

print_screenshot_links() {
    local logs=$1 screenshot
    [[ -d "$logs/commerce-ui-screenshots" ]] || return 0
    (cd "$logs" && find commerce-ui-screenshots -type f -name '*.png' | sort) \
        | while read -r screenshot; do
            echo "Screenshot: ${BUILD_URL:+${BUILD_URL}artifact/}${ORO_ARTIFACTS_PATH:+$ORO_ARTIFACTS_PATH/}$screenshot"
        done
}

print_accessibility_report_link() {
    local logs=$1
    [[ -f "$logs/axe-reports/axe-violations.json" ]] || return 0
    echo "Accessibility report: ${BUILD_URL:+${BUILD_URL}artifact/}${ORO_ARTIFACTS_PATH:+$ORO_ARTIFACTS_PATH/}axe-reports/axe-violations.json"
}

run() {
    local LOGS XDG_BASE
    if [[ ! -d "$APP_SRC" ]]; then
        echo "ERROR: Can't find source"
        exit 1
    fi
    APP_SRC=$(realpath "$APP_SRC")
    if [[ "X$WORKDIR" == "X" ]]; then
        if [[ "$(basename "$(dirname "$APP_SRC")")" == "application" ]]; then
            WORKDIR="$(dirname "$(dirname "$APP_SRC")")"
        else
            WORKDIR=$APP_SRC
        fi
    fi
    if [[ ! -d "$WORKDIR/npm-package" || ! -f "$WORKDIR/pnpm-workspace.yaml" ]]; then
        echo "ERROR: Could not locate the monorepo root (npm-package/ + pnpm-workspace.yaml); resolved WORKDIR='$WORKDIR'"
        exit 1
    fi

    LOGS="$APP_SRC/var/logs"
    mkdir -p "$LOGS/junit"
    rm -rf "$LOGS/junit/npm-packages-browser-commerce-ui.xml" "$LOGS/commerce-ui-coverage" "$LOGS/commerce-ui-screenshots" "$LOGS/axe-reports"
    : >"$LOGS/npm_packages_browser_output.log"

    XDG_BASE="$WORKDIR/var/cache/xdg"
    mkdir -p "$XDG_BASE"/{home,data,cache,config,state,corepack,bin}

    ISOLATED="$WORKDIR/var/npm-iso-browser"
    trap 'rm -rf "$ISOLATED"' EXIT INT TERM
    rm -rf "$ISOLATED"
    mkdir -p "$ISOLATED"
    if ! rsync -a --exclude 'node_modules' "$WORKDIR/npm-package/" "$ISOLATED/npm-package/"; then
        echo "ERROR: failed to assemble isolated npm workspace at $ISOLATED"
        exit 1
    fi
    printf '{ "private": true, "workspaces": [] }\n' >"$ISOLATED/package.json"

    set -x
    set -o pipefail

    docker run --pull always --security-opt label=disable --ipc=host --rm \
        -u "$(id -u):$(id -g)" \
        -v "/etc/group:/etc/group:ro" \
        -v "/etc/passwd:/etc/passwd:ro" \
        -v "$ISOLATED":"$ISOLATED" \
        -v "$LOGS":/reports \
        -v "$XDG_BASE":/xdg \
        -w "$ISOLATED" \
        --env HOME=/xdg/home \
        --env XDG_DATA_HOME=/xdg/data \
        --env XDG_CACHE_HOME=/xdg/cache \
        --env XDG_CONFIG_HOME=/xdg/config \
        --env XDG_STATE_HOME=/xdg/state \
        --env COREPACK_HOME=/xdg/corepack \
        --env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
        --env COMMERCE_UI_AXE_REPORT_DIR=/reports/axe-reports \
        "$PLAYWRIGHT_IMAGE" \
        bash -c '
            set -u
            export PATH="/xdg/bin:$PATH"
            corepack enable --install-directory /xdg/bin pnpm || exit 1
            corepack prepare pnpm@10.33.1 --activate || exit 1
            echo "::: debug: node=$(node -v) pnpm=$(pnpm -v) id=$(id) :::"

            pnpm --dir npm-package/nuxt-storefront install --frozen-lockfile --ignore-scripts || exit 1
            pnpm --dir npm-package/validation run build || exit 1
            pnpm --dir npm-package/commerce-ui run test:coverage \
                --reporter=default --reporter=junit --outputFile.junit=/reports/junit/npm-packages-browser-commerce-ui.xml \
                --reporter=./scripts/axe-violations-reporter.ts \
                --coverage.reportsDirectory=/reports/commerce-ui-coverage \
                --coverage.reporter=text-summary --coverage.reporter=html --coverage.reporter=json
        ' 2>&1 | tee "$LOGS/npm_packages_browser_output.log"

    local rc=${PIPESTATUS[0]}
    (cd "$ISOLATED/npm-package/commerce-ui" && find . -path ./node_modules -prune -o -type d -name __screenshots__ -print) \
        | while read -r screenshots; do
            mkdir -p "$LOGS/commerce-ui-screenshots/${screenshots#./}"
            cp -R "$ISOLATED/npm-package/commerce-ui/$screenshots/." "$LOGS/commerce-ui-screenshots/${screenshots#./}/"
        done

    if [[ $rc -eq 0 ]]; then
        echo -e "${GREEN}commerce-ui browser tests passed.${NC}"
    else
        set +x
        echo -e "${RED}PROBLEM. commerce-ui browser tests failed.${NC}"
        echo "::: summary :::"
        sed 's/\x1b\[[0-9;]*m//g' "$LOGS/npm_packages_browser_output.log" \
            | sed -n -E '/^ FAIL /,/^⎯/p; /^ +Test Files |^ +Tests |ERROR: Coverage|^Accessibility violations in /p'
        print_screenshot_links "$LOGS"
        print_accessibility_report_link "$LOGS"
        echo "Reports saved next to npm_packages_browser_output.log: junit/npm-packages-browser-commerce-ui.xml, commerce-ui-coverage/index.html, commerce-ui-screenshots/, axe-reports/axe-violations.json"
        echo "Storybook links in this log point to localhost:6006 inside the container. Open the same ?path=/story/... in the commerce-ui-storybook artifact of the npm_packages check."
        exit 1
    fi

    [[ $DEBUG ]] || set +x
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
set -e
