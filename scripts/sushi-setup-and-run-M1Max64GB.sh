#!/bin/bash
# sushi-setup-and-run-M1Max64GB.sh
# Complete setup, source build, prebuilt deployment, and background service
# for Sushi LLM server (Qwen3.8-Flash-Next-Sushi-3bpw)
# Optimized for coding, software design, and architecture workloads on Apple Silicon M1 Max (64 GB)

set -e  # Exit on error

# ============================================================================
# CONFIGURATION
# ============================================================================

# Directories
HOME_DIR="${HOME}"
SUSHI_DIR="${HOME_DIR}/.sushi"
MODELS_DIR="${SUSHI_DIR}/model-3.0bpw"
LOGS_DIR="${SUSHI_DIR}/logs"
CACHE_DIR="${SUSHI_DIR}/kv-cache"
PID_DIR="${SUSHI_DIR}/pids"
BIN_DIR="${HOME_DIR}/sushi-macos-arm64"
SUSHI_BIN="${SUSHI_BIN:-}"

# Repository root discovery
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -n "${SCRIPT_DIR}" ] && [ -d "${SCRIPT_DIR}/../.git" ]; then
    REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
elif [ -d "/Users/localadmin/github-sources/sushi/.git" ]; then
    REPO_DIR="/Users/localadmin/github-sources/sushi"
elif [ -d "${PWD}/.git" ]; then
    REPO_DIR="${PWD}"
else
    REPO_DIR=""
fi

# Primary script path
PRIMARY_SCRIPT="/Users/localadmin/github-sources/sushi/scripts/sushi-setup-and-run-M1Max64GB.sh"
if [ ! -f "${PRIMARY_SCRIPT}" ] && [ -n "${SCRIPT_DIR}" ]; then
    PRIMARY_SCRIPT="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
fi

# Release URLs for prebuilt binary auto-update and installation
RELEASE_TAR_URL="https://github.com/beamivalice/sushi/releases/latest/download/sushi-bin-macos-arm64.tar.gz"
RELEASES_API_URL="https://api.github.com/repos/beamivalice/sushi/releases/latest"

# Model configuration
DEFAULT_MODEL_NAME="Qwen3.8-Flash-Next"
DEFAULT_MODEL_REPO="beamster/Qwen3.8-Flash-Next-Sushi-3.0bpw"
MODEL_NAME="${MODEL_NAME:-${DEFAULT_MODEL_NAME}}"
MODEL_REPO="${MODEL_REPO:-${DEFAULT_MODEL_REPO}}"
MODEL_PATH="${MODEL_PATH:-}"
HF_TOKEN="${HF_TOKEN:-}"  # Set via env variable if you have private access

# Server configuration
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8085}"
GPU_WIRED_LIMIT="59000"  # MB for 64 GB Mac

# Inference parameters: Thinking Mode (Default)
PROFILE_NAME="Thinking Mode"
TEMP="${TEMP:-1.0}"
TOP_P="${TOP_P:-0.95}"
TOP_K="${TOP_K:-20}"
MIN_P="${MIN_P:-0.0}"
PRESENCE_PENALTY="${PRESENCE_PENALTY:-0.0}"
REPETITION_PENALTY="${REPETITION_PENALTY:-${REPEAT_PENALTY:-1.0}}"
REPEAT_PENALTY="${REPETITION_PENALTY}"
FREQUENCY_PENALTY="${FREQUENCY_PENALTY:-0.0}"
CTX_SIZE="${CTX_SIZE:-262144}"
MAX_TOKENS="${MAX_TOKENS:-16384}"
REASONING_EFFORT="${REASONING_EFFORT:-medium}"
MAX_CONCURRENT="${MAX_CONCURRENT:-1}"
WIRED_MARGIN_GIB="${WIRED_MARGIN_GIB:-2}"
PREFILL_DECODE_SHARE="${PREFILL_DECODE_SHARE:-0.2}"

GPU_WARM_SECS="${GPU_WARM_SECS:-120}"

# Cache and performance configuration (optimized for 64 GB M1 Max)
PREFIX_CACHE_ENTRIES="${PREFIX_CACHE_ENTRIES:-12}"
PREFIX_CACHE_MEM="${PREFIX_CACHE_MEM:-2GB}"
PREFIX_CACHE_DISK="${PREFIX_CACHE_DISK:-20GB}"
SSM_CHECKPOINT_STRIDE="${SSM_CHECKPOINT_STRIDE:-2048}"
PREFILL_CHUNK="${PREFILL_CHUNK:-2048}"
MTP_DEPTH="${MTP_DEPTH:-3}"
MTP_MIN_DEPTH="${MTP_MIN_DEPTH:-${MTP_DEPTH}}"
MTP_MAX_DEPTH="${MTP_MAX_DEPTH:-${MTP_DEPTH}}"
MTP_TYPICAL="${MTP_TYPICAL:-0.2}"
PRESERVE_THINKING="${PRESERVE_THINKING:-off}"
TOKENIZE_CACHE_ENTRIES="${TOKENIZE_CACHE_ENTRIES:-16}"

# Production & Reliability settings
TIMEOUT="${TIMEOUT:-300}"                  # Stall timeout in seconds
METRICS_ENABLED="${METRICS_ENABLED:-true}"  # Prometheus /metrics endpoint
API_KEY="${API_KEY:-}"                      # Optional API Bearer token
API_KEY_STRICT="${API_KEY_STRICT:-false}"   # Require key from loopback too
LOG_MAX_MB="${LOG_MAX_MB:-100}"             # Log rotation threshold in MB
LOG_BACKUPS="${LOG_BACKUPS:-5}"             # Retained rotated log files
SERVICE_LABEL="com.sushi.llm"
PLIST_PATH="${HOME}/Library/LaunchAgents/${SERVICE_LABEL}.plist"

# PID file for background process management
PID_FILE="${PID_DIR}/sushi.pid"
LOG_FILE="${LOGS_DIR}/sushi.log"

# Color output
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
CYAN=$(printf '\033[0;36m')
NC=$(printf '\033[0m') # No Color

# ============================================================================
# FUNCTIONS
# ============================================================================

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "$1 is not installed. Please install it and try again."
        exit 1
    fi
}

install_latest_sushi() {
    print_info "Downloading latest prebuilt Sushi release from GitHub..."
    mkdir -p "${BIN_DIR}"
    local temp_tar
    temp_tar="$(mktemp "/tmp/sushi-bin-XXXXXX.tar.gz" 2>/dev/null || echo "/tmp/sushi-bin-$$.tar.gz")"
    local temp_dir
    temp_dir="$(mktemp -d "/tmp/sushi-extract-XXXXXX" 2>/dev/null || echo "/tmp/sushi-extract-$$")"
    if curl -fL --retry 3 "${RELEASE_TAR_URL}" -o "${temp_tar}"; then
        tar -xzf "${temp_tar}" -C "${temp_dir}"
        rm -f "${temp_tar}"
        chmod -R u+w "${BIN_DIR}" 2>/dev/null || true
        if [ -d "${temp_dir}/sushi-macos-arm64" ]; then
            cp -Rf "${temp_dir}/sushi-macos-arm64/"* "${BIN_DIR}/"
        else
            cp -Rf "${temp_dir}/"* "${BIN_DIR}/"
        fi
        rm -rf "${temp_dir}"
        chmod +x "${BIN_DIR}/sushi" 2>/dev/null || true
        cp -f "${BIN_DIR}/sushi" "${BIN_DIR}/sushi.release"
        SUSHI_BIN="${BIN_DIR}/sushi"
        local ver
        ver=$("${SUSHI_BIN}" --version 2>/dev/null | awk '/^sushi / {print $2}' || echo "latest")
        cat << EOF > "${BIN_DIR}/.sushi_flavor"
FLAVOR_TYPE=release
FLAVOR_TAG=v${ver}
FLAVOR_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
EOF
        print_success "Installed prebuilt Sushi (${ver}) to ${SUSHI_BIN}"
    else
        rm -f "${temp_tar}"
        rm -rf "${temp_dir}"
        print_error "Failed to download Sushi release from ${RELEASE_TAR_URL}"
        return 1
    fi
}

install_prebuilt_binary() {
    switch_to_release_binary
}

build_and_deploy_from_source() {
    if [ -z "${REPO_DIR}" ] || [ ! -d "${REPO_DIR}" ]; then
        print_error "Sushi git repository not found. Cannot build from source."
        return 1
    fi

    print_info "Building Sushi from source in ${REPO_DIR}..."
    local zig_bin="${REPO_DIR}/.zig-toolchain/zig"
    if [ ! -x "${zig_bin}" ]; then
        if command -v zig &>/dev/null; then
            zig_bin="$(command -v zig)"
        else
            print_error "Zig toolchain not found at ${zig_bin}."
            return 1
        fi
    fi

    # 1. Fetch latest upstream commits
    print_info "Fetching latest commits from upstream (origin/main)..."
    (cd "${REPO_DIR}" && git fetch origin 2>/dev/null || true)

    # 2. Check delta and merge if needed
    local behind_count
    behind_count=$(cd "${REPO_DIR}" && git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    if [ "${behind_count}" -gt 0 ]; then
        print_info "Merging ${behind_count} new upstream commit(s) into local branch..."
        local has_local_changes=false
        if [ -n "$(cd "${REPO_DIR}" && git status --porcelain 2>/dev/null | grep -E '^ M|^M ')" ]; then
            has_local_changes=true
            print_info "Stashing local customizations..."
            (cd "${REPO_DIR}" && git stash push -m "sushi-local-customizations")
        fi
        (cd "${REPO_DIR}" && git merge origin/main)
        if [ "${has_local_changes}" = "true" ]; then
            print_info "Restoring local customizations..."
            (cd "${REPO_DIR}" && git stash pop 2>/dev/null || true)
        fi
    else
        print_success "Local repository is already up to date with origin/main."
    fi

    # 3. Compile ReleaseFast binary
    print_info "Compiling ReleaseFast binary via Zig toolchain (LLVM optimized for Apple Silicon)..."
    (cd "${REPO_DIR}" && "${zig_bin}" build -Doptimize=ReleaseFast)

    if [ ! -f "${REPO_DIR}/zig-out/bin/sushi" ]; then
        print_error "Compilation failed: ${REPO_DIR}/zig-out/bin/sushi not found."
        return 1
    fi

    # 4. Deploy and rewire dynamic libraries
    mkdir -p "${BIN_DIR}"
    cp -f "${REPO_DIR}/zig-out/bin/sushi" "${BIN_DIR}/sushi"
    if command -v install_name_tool >/dev/null 2>&1; then
        install_name_tool -change @rpath/libmlxc.dylib @executable_path/lib/libmlxc.dylib "${BIN_DIR}/sushi" 2>/dev/null || true
        install_name_tool -change /opt/homebrew/opt/webp/lib/libwebp.7.dylib @executable_path/lib/libwebp.dylib "${BIN_DIR}/sushi" 2>/dev/null || true
    fi
    if command -v codesign >/dev/null 2>&1; then
        codesign -s - -f "${BIN_DIR}/sushi" 2>/dev/null || true
    fi
    chmod +x "${BIN_DIR}/sushi"
    cp -f "${BIN_DIR}/sushi" "${BIN_DIR}/sushi.main"
    SUSHI_BIN="${BIN_DIR}/sushi"

    local new_ver
    new_ver=$("${SUSHI_BIN}" --version 2>/dev/null | awk '/^sushi / {print $2}' || echo "latest")
    local head_commit
    head_commit=$(cd "${REPO_DIR}" && git rev-parse --short HEAD 2>/dev/null || echo "main")

    cat << EOF > "${BIN_DIR}/.sushi_flavor"
FLAVOR_TYPE=main
FLAVOR_COMMIT=${head_commit}
FLAVOR_VERSION=${new_ver}
FLAVOR_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
EOF

    print_success "Successfully built and deployed Sushi (${new_ver} @ ${head_commit}) to ${SUSHI_BIN}"
}

switch_to_release_binary() {
    print_info "Switching to official GitHub release binary..."
    mkdir -p "${BIN_DIR}"

    # 1. If active is main build, backup to sushi.main
    if [ -f "${BIN_DIR}/sushi" ]; then
        local current_flavor="unknown"
        if [ -f "${BIN_DIR}/.sushi_flavor" ]; then
            current_flavor=$(grep "^FLAVOR_TYPE=" "${BIN_DIR}/.sushi_flavor" | cut -d= -f2 || echo "unknown")
        fi
        if [ "${current_flavor}" = "main" ] || [ ! -f "${BIN_DIR}/sushi.main" ]; then
            cp -f "${BIN_DIR}/sushi" "${BIN_DIR}/sushi.main"
        fi
    fi

    # 2. If sushi.release or sushi.v1.1.1.original is cached locally, restore it
    if [ -f "${BIN_DIR}/sushi.release" ]; then
        cp -f "${BIN_DIR}/sushi.release" "${BIN_DIR}/sushi"
        chmod +x "${BIN_DIR}/sushi"
        print_info "Restored cached release binary from ${BIN_DIR}/sushi.release"
    elif [ -f "${BIN_DIR}/sushi.v1.1.1.original" ]; then
        cp -f "${BIN_DIR}/sushi.v1.1.1.original" "${BIN_DIR}/sushi.release"
        cp -f "${BIN_DIR}/sushi.v1.1.1.original" "${BIN_DIR}/sushi"
        chmod +x "${BIN_DIR}/sushi"
        print_info "Restored original release binary from ${BIN_DIR}/sushi.v1.1.1.original"
    else
        install_latest_sushi || return 1
    fi

    SUSHI_BIN="${BIN_DIR}/sushi"
    local ver
    ver=$("${SUSHI_BIN}" --version 2>/dev/null | awk '/^sushi / {print $2}' || echo "1.1.1")

    cat << EOF > "${BIN_DIR}/.sushi_flavor"
FLAVOR_TYPE=release
FLAVOR_TAG=v${ver}
FLAVOR_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
EOF

    print_success "Active engine is now: Official GitHub Release (v${ver})"
    echo ""
    echo -e "${CYAN}Deployment Summary:${NC}"
    echo "  Binary: ${SUSHI_BIN} [Official Release v${ver}]"
    if [ -n "${REPO_DIR}" ] && [ -d "${REPO_DIR}" ]; then
        local ahead_count
        ahead_count=$(cd "${REPO_DIR}" && git rev-list --count "v${ver}..HEAD" 2>/dev/null || echo 0)
        echo "  Main Branch Delta: ${ahead_count} newer commits available"
        echo "  To switch back to bleeding-edge main build anytime, run:"
        echo -e "    ${GREEN}$0 use-main${NC}"
    fi
    echo ""

    # Restart running instance if active
    if command -v launchctl >/dev/null 2>&1 && launchctl list 2>/dev/null | grep -q "${SERVICE_LABEL}"; then
        print_info "Restarting launchd service to apply release binary..."
        restart_service
    elif check_running; then
        print_info "Restarting standalone server to apply release binary..."
        stop_server
        sleep 2
        start_server
    fi
}

switch_to_main_binary() {
    print_info "Switching to 'main' branch build..."
    mkdir -p "${BIN_DIR}"

    local needs_build=false
    if [ ! -f "${BIN_DIR}/sushi.main" ]; then
        needs_build=true
    fi

    # Check if there are unbuilt commits in local repo or upstream
    if [ -n "${REPO_DIR}" ] && [ -d "${REPO_DIR}" ]; then
        local current_flavor_commit=""
        if [ -f "${BIN_DIR}/.sushi_flavor" ]; then
            current_flavor_commit=$(grep "^FLAVOR_COMMIT=" "${BIN_DIR}/.sushi_flavor" | cut -d= -f2 || echo "")
        fi
        local head_commit
        head_commit=$(cd "${REPO_DIR}" && git rev-parse --short HEAD 2>/dev/null || echo "")
        if [ -n "${current_flavor_commit}" ] && [ -n "${head_commit}" ] && [ "${current_flavor_commit}" != "${head_commit}" ]; then
            needs_build=true
        fi

        (cd "${REPO_DIR}" && git fetch origin 2>/dev/null || true)
        local behind_count
        behind_count=$(cd "${REPO_DIR}" && git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
        if [ "${behind_count}" -gt 0 ] || [ "${1:-}" = "--rebuild" ] || [ "${1:-}" = "-f" ]; then
            needs_build=true
        fi
    fi

    if [ "${needs_build}" = "true" ]; then
        # Backup release binary first if active
        if [ -f "${BIN_DIR}/sushi" ]; then
            local current_flavor="unknown"
            if [ -f "${BIN_DIR}/.sushi_flavor" ]; then
                current_flavor=$(grep "^FLAVOR_TYPE=" "${BIN_DIR}/.sushi_flavor" | cut -d= -f2 || echo "unknown")
            fi
            if [ "${current_flavor}" = "release" ] || [ ! -f "${BIN_DIR}/sushi.release" ]; then
                cp -f "${BIN_DIR}/sushi" "${BIN_DIR}/sushi.release"
            fi
        fi
        build_and_deploy_from_source || return 1
    else
        # Backup active binary to release cache if flavor was release
        if [ -f "${BIN_DIR}/sushi" ]; then
            cp -f "${BIN_DIR}/sushi" "${BIN_DIR}/sushi.release"
        fi
        cp -f "${BIN_DIR}/sushi.main" "${BIN_DIR}/sushi"
        chmod +x "${BIN_DIR}/sushi"
        SUSHI_BIN="${BIN_DIR}/sushi"
        print_info "Restored cached main build from ${BIN_DIR}/sushi.main"
    fi

    local head_commit
    head_commit=$(cd "${REPO_DIR}" && git rev-parse --short HEAD 2>/dev/null || echo "main")
    local ver
    ver=$("${SUSHI_BIN}" --version 2>/dev/null | awk '/^sushi / {print $2}' || echo "1.1.1")

    cat << EOF > "${BIN_DIR}/.sushi_flavor"
FLAVOR_TYPE=main
FLAVOR_COMMIT=${head_commit}
FLAVOR_VERSION=${ver}
FLAVOR_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
EOF

    print_success "Active engine is now: 'main' branch build (${ver} @ ${head_commit})"
    echo ""
    if [ -n "${REPO_DIR}" ] && [ -d "${REPO_DIR}" ]; then
        echo -e "${CYAN}Active Delta Features & Fixes over v${ver} Release:${NC}"
        (cd "${REPO_DIR}" && git log --format="  • %s" -n 8 HEAD)
        echo ""
        echo "  To rollback to official GitHub release binary anytime, run:"
        echo -e "    ${GREEN}$0 use-release${NC}"
    fi
    echo ""

    # Restart running instance if active
    if command -v launchctl >/dev/null 2>&1 && launchctl list 2>/dev/null | grep -q "${SERVICE_LABEL}"; then
        print_info "Restarting launchd service to apply 'main' build..."
        restart_service
    elif check_running; then
        print_info "Restarting standalone server to apply 'main' build..."
        stop_server
        sleep 2
        start_server
    fi
}

check_all_updates() {
    print_info "Inspecting updates across installed binary, GitHub releases, and git main branch..."
    
    local current_bin_ver
    current_bin_ver=$("${SUSHI_BIN:-${BIN_DIR}/sushi}" --version 2>/dev/null | awk '/^sushi / {print $2}' || echo "unknown")

    # 1. Check GitHub Release
    local release_info
    release_info=$(python3 -c '
import json, urllib.request, sys
try:
    req = urllib.request.Request("https://api.github.com/repos/beamivalice/sushi/releases/latest", headers={"User-Agent": "sushi-setup"})
    with urllib.request.urlopen(req, timeout=6) as resp:
        data = json.loads(resp.read().decode())
    print(data.get("tag_name", "").strip())
    print("---BODY---")
    print(data.get("body", "").strip())
except Exception:
    sys.exit(1)
' 2>/dev/null || true)

    local latest_rel_tag latest_rel_ver rel_body
    latest_rel_tag=$(echo "${release_info}" | head -1)
    latest_rel_ver="${latest_rel_tag#v}"
    rel_body=$(echo "${release_info}" | sed -n '/^---BODY---$/,$p' | tail -n +2)

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}  Sushi Comprehensive Version & Delta Inspector (M1 Max 64 GB)${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo "  Installed Binary:       ${SUSHI_BIN:-${BIN_DIR}/sushi} (${current_bin_ver})"
    echo "  Latest GitHub Release:  ${latest_rel_tag:-unknown}"
    
    if [ -n "${REPO_DIR}" ] && [ -d "${REPO_DIR}" ]; then
        (cd "${REPO_DIR}" && git fetch origin 2>/dev/null || true)
        local local_commit upstream_commit behind_count
        local_commit=$(cd "${REPO_DIR}" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        upstream_commit=$(cd "${REPO_DIR}" && git rev-parse --short origin/main 2>/dev/null || echo "unknown")
        behind_count=$(cd "${REPO_DIR}" && git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
        local ahead_release_count
        ahead_release_count=$(cd "${REPO_DIR}" && git rev-list --count "v${latest_rel_ver:-1.1.1}..HEAD" 2>/dev/null || echo 0)
        
        echo "  Git Local Commit:       ${local_commit}"
        echo "  Git Upstream Commit:    ${upstream_commit} (origin/main)"
        echo "  Commits Behind Upstream: ${behind_count}"
        echo "  Commits Ahead Release:   ${ahead_release_count}"
        echo -e "${BLUE}----------------------------------------------------------------${NC}"
        
        if [ "${behind_count}" -gt 0 ]; then
            echo -e "${YELLOW}[!] Upstream main has ${behind_count} new commit(s) ready to build:${NC}"
            (cd "${REPO_DIR}" && git log --oneline -n 10 HEAD..origin/main)
            echo ""
            echo -e "${CYAN}What's new in upstream main:${NC}"
            (cd "${REPO_DIR}" && git log --format="  • %s" -n 8 HEAD..origin/main)
        else
            echo -e "${GREEN}[✓] Local source build is fully up to date with origin/main.${NC}"
            echo -e "${CYAN}Recent source features integrated:${NC}"
            (cd "${REPO_DIR}" && git log --format="  • %s" -n 6 HEAD)
        fi
    fi

    if [ -n "${rel_body}" ]; then
        echo -e "${BLUE}----------------------------------------------------------------${NC}"
        echo -e "${BLUE}Latest Official GitHub Release Notes (${latest_rel_tag}):${NC}"
        echo "${rel_body}" | head -n 15
    fi
    echo -e "${BLUE}================================================================${NC}"
    echo ""
}

ensure_latest_sushi_binary() {
    # 1. If explicit SUSHI_BIN is set, verify and use it
    if [ -n "${SUSHI_BIN:-}" ]; then
        if [ ! -x "${SUSHI_BIN}" ]; then
            print_error "Configured SUSHI_BIN is not executable: ${SUSHI_BIN}"
            exit 1
        fi
        print_info "Using configured SUSHI_BIN: ${SUSHI_BIN}"
        return 0
    fi

    # 2. Identify candidate binaries
    local candidates=()
    if [ -x "${BIN_DIR}/sushi" ]; then
        candidates+=("${BIN_DIR}/sushi")
    fi
    if [ -n "${REPO_DIR}" ] && [ -x "${REPO_DIR}/zig-out/bin/sushi" ]; then
        candidates+=("${REPO_DIR}/zig-out/bin/sushi")
    fi
    if command -v sushi &>/dev/null; then
        candidates+=("$(command -v sushi)")
    fi

    if [ ${#candidates[@]} -eq 0 ]; then
        print_info "No Sushi binary found. Installing latest prebuilt release..."
        install_latest_sushi || exit 1
        return 0
    fi

    SUSHI_BIN="${BIN_DIR}/sushi"
    if [ ! -x "${SUSHI_BIN}" ]; then
        SUSHI_BIN=$(ls -t "${candidates[@]}" 2>/dev/null | head -1)
    fi

    local current_ver
    current_ver=$("${SUSHI_BIN}" --version 2>/dev/null | awk '/^sushi / {print $2}' || echo "1.1.1")

    # Read flavor metadata if available
    local flavor_type="unknown"
    local flavor_commit=""
    if [ -f "${BIN_DIR}/.sushi_flavor" ]; then
        flavor_type=$(grep "^FLAVOR_TYPE=" "${BIN_DIR}/.sushi_flavor" | cut -d= -f2 || echo "unknown")
        flavor_commit=$(grep "^FLAVOR_COMMIT=" "${BIN_DIR}/.sushi_flavor" | cut -d= -f2 || echo "")
    fi

    if [ "${flavor_type}" = "release" ]; then
        print_success "Sushi Engine: Running official GitHub Release (v${current_ver})"
        if [ -n "${REPO_DIR}" ] && [ -d "${REPO_DIR}" ]; then
            local ahead_count
            ahead_count=$(cd "${REPO_DIR}" && git rev-list --count "v${current_ver}..HEAD" 2>/dev/null || echo 0)
            if [ "${ahead_count}" -gt 0 ]; then
                print_info "Note: ${ahead_count} newer commit(s) available on 'main' branch (run '$0 use-main' to switch)"
            fi
        fi
    else
        # Default or flavor_type == 'main'
        if [ -n "${REPO_DIR}" ] && [ -d "${REPO_DIR}" ]; then
            local repo_head_commit current_binary_commit
            repo_head_commit=$(cd "${REPO_DIR}" && git rev-parse --short HEAD 2>/dev/null || echo "")
            current_binary_commit="${flavor_commit:-}"

            # If the deployed binary was built from an older commit than current git HEAD, prompt or rebuild
            if [ -n "${repo_head_commit}" ] && [ -n "${current_binary_commit}" ] && [ "${repo_head_commit}" != "${current_binary_commit}" ]; then
                local unbuilt_count
                unbuilt_count=$(cd "${REPO_DIR}" && git rev-list --count "${current_binary_commit}..HEAD" 2>/dev/null || echo 0)
                if [ "${unbuilt_count}" -gt 0 ]; then
                    echo ""
                    echo -e "${YELLOW}================================================================${NC}"
                    echo -e "${YELLOW}[!] New commits detected in git repository since last build:${NC}"
                    echo -e "${YELLOW}    ${unbuilt_count} unbuilt commit(s) (${current_binary_commit} -> ${repo_head_commit})${NC}"
                    echo -e "${YELLOW}================================================================${NC}"
                    (cd "${REPO_DIR}" && git log --format="  • %s" -n 5 "${current_binary_commit}..HEAD")
                    echo -e "${YELLOW}================================================================${NC}"
                    echo ""

                    local do_rebuild="y"
                    if [ -t 0 ]; then
                        read -r -p "Do you want to recompile and deploy the latest binary now? [Y/n] " do_rebuild
                        do_rebuild="${do_rebuild:-y}"
                    else
                        print_info "Non-interactive session: automatically compiling latest binary..."
                        do_rebuild="y"
                    fi

                    case "${do_rebuild}" in
                        [yY][eE][sS]|[yY])
                            print_info "Rebuilding and deploying latest binary from source..."
                            build_and_deploy_from_source || return 1
                            current_ver=$("${SUSHI_BIN}" --version 2>/dev/null | awk '/^sushi / {print $2}' || echo "1.1.1")
                            current_binary_commit="${repo_head_commit}"
                            ;;
                        *)
                            print_info "Skipping build; continuing with current binary (${current_binary_commit})."
                            ;;
                    esac
                fi
            fi

            local ahead_release_count behind_count
            ahead_release_count=$(cd "${REPO_DIR}" && git rev-list --count "v${current_ver}..HEAD" 2>/dev/null || echo 0)
            
            if [ "${ahead_release_count}" -gt 0 ]; then
                print_success "Sushi Engine: Running 'main' branch build (${current_binary_commit:-${repo_head_commit}}, ${ahead_release_count} commits ahead of v${current_ver} release)"
                echo -e "${CYAN}Active Delta Features & Fixes over v${current_ver}:${NC}"
                (cd "${REPO_DIR}" && git log --format="  • %s" -n 6 HEAD)
                print_info "Note: You can rollback to the official release binary anytime via '$0 use-release'"
            else
                print_success "Sushi Engine: Running Sushi binary v${current_ver} (${SUSHI_BIN})"
            fi

            behind_count=$(cd "${REPO_DIR}" && git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
            if [ "${behind_count}" -gt 0 ]; then
                print_info "Note: ${behind_count} newer commit(s) available on upstream origin/main (run '$0 build' to update)"
            fi
        else
            print_success "Sushi binary is ready (${current_ver}): ${SUSHI_BIN}"
        fi
    fi
}

check_sushi_binary() {
    ensure_latest_sushi_binary
    if [ ! -x "${SUSHI_BIN}" ]; then
        print_error "Sushi binary not found or not executable at ${SUSHI_BIN}"
        exit 1
    fi
}

setup_directories() {
    print_info "Setting up directories..."
    mkdir -p "${MODELS_DIR}"
    mkdir -p "${LOGS_DIR}"
    mkdir -p "${CACHE_DIR}"
    mkdir -p "${PID_DIR}"
    print_success "Directories created"
}

set_gpu_memory_limit() {
    print_info "Checking GPU memory limit (target: ${GPU_WIRED_LIMIT} MB for 64 GB M1 Max)..."
    
    CURRENT_LIMIT=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo "0")
    
    if [ "${CURRENT_LIMIT}" != "${GPU_WIRED_LIMIT}" ]; then
        print_warning "Current GPU wired limit: ${CURRENT_LIMIT} MB"
        if sudo -n sysctl iogpu.wired_limit_mb="${GPU_WIRED_LIMIT}" 2>/dev/null; then
            print_success "GPU memory limit set to ${GPU_WIRED_LIMIT} MB"
            print_warning "This limit resets on reboot."
        else
            print_warning "Setting iogpu.wired_limit_mb=${GPU_WIRED_LIMIT} requires sudo."
            print_warning "Run this command in your terminal: sudo sysctl iogpu.wired_limit_mb=${GPU_WIRED_LIMIT}"
        fi
    else
        print_success "GPU memory limit already set to ${GPU_WIRED_LIMIT} MB"
    fi
}

is_model_complete() {
    local p="$1"
    [ -n "${p}" ] && [ -d "${p}" ] && [ -f "${p}/config.json" ] || return 1
    local weights
    weights=$(find "${p}" -maxdepth 1 \( -name "*.safetensors" -o -name "*.gguf" \) -print -quit 2>/dev/null)
    [ -n "${weights}" ] || return 1
    local partials
    partials=$(find "${p}" -maxdepth 2 -name "*.partial" -print -quit 2>/dev/null)
    [ -z "${partials}" ] || return 1
    return 0
}

resolve_latest_model() {
    if [ -n "${MODEL_PATH}" ] && is_model_complete "${MODEL_PATH}"; then
        MODEL_NAME="$(basename "${MODEL_PATH}")"
        print_info "Using explicitly configured MODEL_PATH: ${MODEL_PATH}"
        return 0
    fi

    if [ -n "${MODEL_NAME}" ]; then
        local named_candidates=(
            "${MODELS_DIR}/${MODEL_NAME}"
            "${MODELS_DIR}"/*/"${MODEL_NAME}"
        )
        for c in "${named_candidates[@]}"; do
            if is_model_complete "${c}"; then
                MODEL_PATH="${c}"
                print_info "Found configured model: ${MODEL_NAME} (${MODEL_PATH})"
                return 0
            fi
        done
    fi

    print_info "Scanning ${MODELS_DIR} for latest model..."
    local all_candidates=()
    for d in "${MODELS_DIR}"/*; do
        [ -d "${d}" ] || continue
        case "$(basename "${d}")" in .* ) continue ;; esac
        if is_model_complete "${d}"; then
            all_candidates+=("${d}")
        else
            for sub in "${d}"/*; do
                [ -d "${sub}" ] || continue
                case "$(basename "${sub}")" in .* ) continue ;; esac
                if is_model_complete "${sub}"; then
                    all_candidates+=("${sub}")
                fi
            done
        fi
    done

    if [ ${#all_candidates[@]} -gt 0 ]; then
        MODEL_PATH=$(ls -td "${all_candidates[@]}" 2>/dev/null | head -1)
        MODEL_NAME="$(basename "${MODEL_PATH}")"
        print_success "Automatically picked latest model: ${MODEL_NAME} (${MODEL_PATH})"
        return 0
    fi

    MODEL_NAME="${DEFAULT_MODEL_NAME}"
    MODEL_REPO="${DEFAULT_MODEL_REPO}"
    MODEL_PATH="${MODELS_DIR}/${MODEL_NAME}"
    return 1
}

sync_model_files() {
    local repo="$1"
    local dest="$2"
    local token_args=()
    if [ -n "${HF_TOKEN}" ]; then
        token_args=(--token "${HF_TOKEN}")
    fi

    if command -v hf &>/dev/null; then
        HF_HOME="${HOME_DIR}/.cache/huggingface" hf download "${repo}" \
            --local-dir "${dest}" "${token_args[@]}" || {
            print_warning "Failed to update model with 'hf'"
            return 1
        }
    elif command -v huggingface-cli &>/dev/null; then
        HF_HOME="${HOME_DIR}/.cache/huggingface" huggingface-cli download "${repo}" \
            --local-dir "${dest}" "${token_args[@]}" || {
            print_warning "Failed to update model with 'huggingface-cli'"
            return 1
        }
    elif [ -x "${SUSHI_BIN}" ]; then
        print_info "Using sushi pull to update model..."
        HF_TOKEN="${HF_TOKEN}" "${SUSHI_BIN}" pull "${repo}" || {
            print_warning "Failed to update model with 'sushi pull'"
            return 1
        }
    else
        print_error "No download tool found (hf, huggingface-cli, or sushi binary)."
        return 1
    fi
    print_success "Model update complete at ${dest}"
    return 0
}

check_and_prompt_model_update() {
    [ -n "${MODEL_PATH}" ] && [ -d "${MODEL_PATH}" ] || return 0
    local repo="${MODEL_REPO:-beamster/${MODEL_NAME}}"

    print_info "Checking Hugging Face for updates to ${repo}..."
    local diff_output
    diff_output=$(python3 -c '
import json, os, sys, urllib.request

repo = sys.argv[1]
local_dir = sys.argv[2]
token = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

headers = {"User-Agent": "sushi-check"}
if token:
    headers["Authorization"] = f"Bearer {token}"

url = f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true"
try:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=8) as resp:
        data = json.loads(resp.read().decode())
except Exception as e:
    sys.exit(2)

diffs = []
for item in data:
    if item.get("type") != "file":
        continue
    rel = item["path"]
    r_size = item.get("size", 0)
    full = os.path.join(local_dir, rel)
    if not os.path.exists(full):
        diffs.append(f"NEW: {rel} ({r_size:,} bytes)")
    else:
        l_size = os.path.getsize(full)
        if r_size > 0 and l_size != r_size:
            diffs.append(f"CHANGED: {rel} (local: {l_size:,} bytes -> remote: {r_size:,} bytes)")

if diffs:
    print(f"FOUND {len(diffs)}")
    for d in diffs:
        print(d)
else:
    print("UP_TO_DATE")
' "${repo}" "${MODEL_PATH}" "${HF_TOKEN}" 2>/dev/null || true)

    if echo "${diff_output}" | grep -q "^FOUND"; then
        local count
        count=$(echo "${diff_output}" | head -1 | awk '{print $2}')
        echo ""
        echo -e "${YELLOW}================================================================${NC}"
        echo -e "${YELLOW}[!] Model file updates available on Hugging Face (${repo}):${NC}"
        echo -e "${YELLOW}    ${count} file(s) changed or new${NC}"
        echo -e "${YELLOW}================================================================${NC}"
        echo -e "${BLUE}Changed Files:${NC}"
        echo "${diff_output}" | tail -n +2 | head -n 25 | while read -r line; do
            echo "  - ${line}"
        done
        local total_lines
        total_lines=$(echo "${diff_output}" | tail -n +2 | wc -l | tr -d ' ')
        if [ "${total_lines}" -gt 25 ]; then
            echo "  ... and $((total_lines - 25)) more file(s)"
        fi
        echo -e "${YELLOW}================================================================${NC}"
        echo ""

        local choice="n"
        if [ -t 0 ]; then
            read -r -p "Do you want to download model updates now? [Y/n] " choice
            choice="${choice:-y}"
        else
            print_info "Non-interactive session detected; continuing with local model files."
            choice="n"
        fi

        case "${choice}" in
            [yY][eE][sS]|[yY])
                print_info "Updating model files..."
                sync_model_files "${repo}" "${MODEL_PATH}"
                ;;
            *)
                print_info "Continuing with local model at ${MODEL_PATH}"
                ;;
        esac
    elif [ "${diff_output}" = "UP_TO_DATE" ]; then
        print_success "Model files are up to date on Hugging Face (${repo})"
    else
        print_info "Could not verify model files on Hugging Face (offline or unavailable). Continuing with local model."
    fi
}

download_model() {
    if resolve_latest_model; then
        print_success "Complete model already available at ${MODEL_PATH}"
        check_and_prompt_model_update
        return 0
    fi
    
    local repo="${MODEL_REPO:-${DEFAULT_MODEL_REPO}}"
    print_info "No complete model found in ${MODELS_DIR}."
    print_info "Downloading model: ${repo}..."
    print_info "This may take several minutes (model is ~47 GB)..."
    
    sync_model_files "${repo}" "${MODEL_PATH}" || exit 1
    
    if resolve_latest_model; then
        print_success "Model ready at ${MODEL_PATH}"
    else
        print_error "Model download did not complete successfully at ${MODEL_PATH}"
        exit 1
    fi
}

check_running() {
    if [ -f "${PID_FILE}" ]; then
        PID=$(cat "${PID_FILE}" 2>/dev/null || true)
        if [ -n "${PID}" ] && kill -0 "${PID}" 2>/dev/null; then
            return 0
        else
            rm -f "${PID_FILE}"
            return 1
        fi
    fi
    return 1
}

rotate_logs() {
    local target_files=("${LOG_FILE}" "${LOGS_DIR}/sushi-console.log" "${LOGS_DIR}/sushi-launchd.log")
    local max_bytes=$((LOG_MAX_MB * 1024 * 1024))
    
    for f in "${target_files[@]}"; do
        if [ -f "$f" ]; then
            local size
            size=$(stat -f%z "$f" 2>/dev/null || wc -c < "$f" 2>/dev/null || echo 0)
            if [ "${size}" -ge "${max_bytes}" ]; then
                print_info "Log file $f exceeds ${LOG_MAX_MB}MB (${size} bytes). Rotating..."
                rm -f "${f}.${LOG_BACKUPS}.gz" 2>/dev/null || true
                for ((i = LOG_BACKUPS - 1; i >= 1; i--)); do
                    local prev="${f}.${i}.gz"
                    local next="${f}.$((i + 1)).gz"
                    if [ -f "${prev}" ]; then
                        mv -f "${prev}" "${next}"
                    fi
                done
                mv -f "$f" "${f}.1"
                gzip -f "${f}.1" 2>/dev/null || true
                touch "$f"
                print_success "Rotated $f (archived to ${f}.1.gz)"
            fi
        fi
    done
}

generate_plist() {
    local target_script="${PRIMARY_SCRIPT}"
    if [ ! -f "${target_script}" ]; then
        target_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    fi

    local work_dir="${REPO_DIR}"
    if [ -z "${work_dir}" ] || [ ! -d "${work_dir}" ]; then
        work_dir="${SUSHI_DIR}"
    fi

    mkdir -p "$(dirname "${PLIST_PATH}")"
    cat << EOF > "${PLIST_PATH}"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${target_script}</string>
        <string>run-service</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Standard</string>
    <key>WorkingDirectory</key>
    <string>${work_dir}</string>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/sushi-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/sushi-launchd.log</string>
    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>65536</integer>
    </dict>
    <key>HardResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>65536</integer>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.local/bin:${HOME}/bin:${BIN_DIR}</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
</dict>
</plist>
EOF
    print_success "Generated launchd plist at ${PLIST_PATH}"
}

install_service() {
    print_info "Configuring macOS launchd daemon service..."
    generate_plist
    print_success "LaunchAgent configuration installed at ${PLIST_PATH}"
    echo ""
    print_info "To register and start the daemon with auto-restart on exit/crash:"
    echo "  $0 start-service"
    echo ""
    print_info "To monitor launchd status: $0 service-status"
}

start_service() {
    print_info "Starting Sushi under macOS launchd supervision (auto-restart if stopped)..."
    
    # 1. Identify active binary and display delta / version banner in console
    ensure_latest_sushi_binary

    # 2. Stop any currently running standalone instance
    if check_running; then
        print_info "Stopping standalone instance first..."
        PID=$(cat "${PID_FILE}" 2>/dev/null || true)
        if [ -n "${PID}" ]; then
            kill -TERM "${PID}" 2>/dev/null || true
            for _ in {1..15}; do
                if ! kill -0 "${PID}" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            if kill -0 "${PID}" 2>/dev/null; then
                kill -9 "${PID}" 2>/dev/null || true
            fi
            rm -f "${PID_FILE}"
        fi
    fi

    # 3. Ensure launchd plist is current
    generate_plist

    # 4. Register and load with launchd
    if command -v launchctl >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null || launchctl unload "${PLIST_PATH}" 2>/dev/null || true
        sleep 1
        print_info "Registering service with launchctl..."
        if ! launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null; then
            launchctl load "${PLIST_PATH}" 2>/dev/null || true
        fi
    fi

    # 5. Wait for server to come up and verify health
    print_info "Waiting for Sushi server to become healthy..."
    local connect_host="$([ "${HOST}" = "0.0.0.0" ] && echo "127.0.0.1" || echo "${HOST}")"
    for i in {1..60}; do
        if curl -sf "http://${connect_host}:${PORT}/health" > /dev/null 2>&1; then
            print_success "Sushi server is active under launchd supervision!"
            local cur_pid
            cur_pid=$(cat "${PID_FILE}" 2>/dev/null || pgrep -f "sushi serve" | head -n 1 || echo "")
            if [ -n "${cur_pid}" ]; then
                print_success "Process PID: ${cur_pid}"
            fi
            print_success "Auto-restart is ACTIVE: if the server stops or crashes, macOS launchd will restart it immediately."
            echo ""
            echo -e "${GREEN}Server is ready on port ${PORT}!${NC}"
            echo "Local API endpoint:   http://127.0.0.1:${PORT}/v1/chat/completions"
            echo "Network API endpoint: http://${HOST}:${PORT}/v1/chat/completions"
            echo "Prometheus metrics:   http://${HOST}:${PORT}/metrics"
            echo "Health check:         curl http://127.0.0.1:${PORT}/health"
            return 0
        fi
        sleep 1
    done

    print_warning "Server starting up... Check logs: tail -f ${LOGS_DIR}/sushi-launchd.log"
}

stop_service() {
    print_info "Stopping launchd service (${SERVICE_LABEL})..."
    if command -v launchctl >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null || launchctl unload "${PLIST_PATH}" 2>/dev/null || true
    fi
    stop_server
    print_success "Service stopped"
}

restart_service() {
    stop_service
    sleep 2
    start_service
}

uninstall_service() {
    print_info "Uninstalling macOS launchd service..."
    if command -v launchctl >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null || launchctl unload "${PLIST_PATH}" 2>/dev/null || true
    fi
    if [ -f "${PLIST_PATH}" ]; then
        rm -f "${PLIST_PATH}"
        print_success "Removed LaunchAgent plist: ${PLIST_PATH}"
    else
        print_warning "LaunchAgent plist not found: ${PLIST_PATH}"
    fi
}

service_status() {
    print_info "Checking launchd service status for ${SERVICE_LABEL}..."
    if command -v launchctl >/dev/null 2>&1; then
        if launchctl list 2>/dev/null | grep -q "${SERVICE_LABEL}"; then
            print_success "Service '${SERVICE_LABEL}' is loaded in launchd:"
            launchctl list "${SERVICE_LABEL}" 2>/dev/null || launchctl list | grep "${SERVICE_LABEL}"
        else
            print_warning "Service '${SERVICE_LABEL}' is NOT currently loaded in launchctl."
        fi
    fi
    if [ -f "${PLIST_PATH}" ]; then
        print_info "Plist file: ${PLIST_PATH} (exists)"
    else
        print_warning "Plist file: ${PLIST_PATH} (missing - run '$0 install-service' to create)"
    fi
    status
}

query_metrics() {
    local endpoint="metrics"
    if [ "${1:-}" = "--json" ] || [ "${1:-}" = "json" ]; then
        endpoint="metrics.json"
    fi
    local connect_host="$([ "${HOST}" = "0.0.0.0" ] && echo "127.0.0.1" || echo "${HOST}")"
    local auth_header=()
    if [ -n "${API_KEY}" ]; then
        auth_header=(-H "Authorization: Bearer ${API_KEY}")
    fi
    print_info "Fetching Prometheus metrics from http://${connect_host}:${PORT}/${endpoint}..."
    curl -s "${auth_header[@]}" "http://${connect_host}:${PORT}/${endpoint}" || {
        echo ""
        print_warning "Could not retrieve metrics. (Ensure server is started with --metrics)"
    }
}

run_service() {
    # File descriptor limit: macOS defaults to 256/1024; production servers need 65536
    ulimit -n 65536 2>/dev/null || ulimit -n 8192 2>/dev/null || true

    setup_directories
    rotate_logs
    ensure_latest_sushi_binary
    if ! resolve_latest_model; then
        print_error "No complete model found in ${MODELS_DIR}."
        exit 1
    fi

    # Save PID so 'status' and 'test' commands know we are running
    echo "$$" > "${PID_FILE}"
    trap 'rm -f "${PID_FILE}"; exit 0' SIGTERM SIGINT EXIT

    local launcher=()
    if command -v taskpolicy >/dev/null 2>&1; then
        launcher=(taskpolicy -a)
    fi

    local chunk_args=()
    if [ -n "${PREFILL_CHUNK}" ] && [ "${PREFILL_CHUNK}" != "auto" ]; then
        chunk_args=(--prefill-chunk "${PREFILL_CHUNK}")
    fi

    local extra_args=()
    if [ -n "${GPU_WARM_SECS}" ] && [ "${GPU_WARM_SECS}" != "0" ]; then
        extra_args+=(--gpu-warm-secs "${GPU_WARM_SECS}")
    fi
    if [ -n "${REASONING_EFFORT}" ]; then
        extra_args+=(--think "${REASONING_EFFORT}")
    fi

    local prod_args=()
    if [ "${METRICS_ENABLED}" = "true" ]; then
        prod_args+=(--metrics)
    fi
    if [ -n "${TIMEOUT}" ] && [ "${TIMEOUT}" != "0" ]; then
        prod_args+=(--timeout "${TIMEOUT}")
    fi
    if [ -n "${API_KEY}" ]; then
        export SUSHI_API_KEY="${API_KEY}"
        prod_args+=(--api-key-env SUSHI_API_KEY)
        if [ "${API_KEY_STRICT}" = "true" ]; then
            prod_args+=(--api-key-strict)
        fi
    fi

    print_info "Executing Sushi in foreground under launchd supervision (PID: $$)..."
    exec "${launcher[@]}" "${SUSHI_BIN}" serve \
        --model "${MODEL_PATH}" \
        --host "${HOST}" \
        --port "${PORT}" \
        --mtp \
        --mtp-min-depth "${MTP_MIN_DEPTH}" \
        --mtp-max-depth "${MTP_MAX_DEPTH}" \
        --kv-quant 4 \
        --mtp-head-kv-quant \
        --skip-mem-preflight \
        --ctx-size "${CTX_SIZE}" \
        --max-tokens "${MAX_TOKENS}" \
        --preserve-thinking "${PRESERVE_THINKING}" \
        --prefix-cache-disk "${PREFIX_CACHE_DISK}" \
        --prefix-cache-entries "${PREFIX_CACHE_ENTRIES}" \
        --prefix-cache-mem "${PREFIX_CACHE_MEM}" \
        --wired-margin-gib "${WIRED_MARGIN_GIB}" \
        --prefill-decode-share "${PREFILL_DECODE_SHARE}" \
        --no-update-check \
        "${chunk_args[@]}" \
        "${extra_args[@]}" \
        "${prod_args[@]}" \
        --temp "${TEMP}" \
        --top-p "${TOP_P}" \
        --top-k "${TOP_K}" \
        --max-concurrent "${MAX_CONCURRENT}" \
        --mtp-typical "${MTP_TYPICAL}" \
        --ssm-checkpoint-stride "${SSM_CHECKPOINT_STRIDE}" \
        --tokenize-cache-entries "${TOKENIZE_CACHE_ENTRIES}" \
        --log-level info \
        --log-file "${LOG_FILE}"
}

start_server() {
    if check_running; then
        print_info "Sushi is already running. Use 'stop' command to stop it first."
        return 0
    fi

    # Set file descriptor limit for production concurrency
    ulimit -n 65536 2>/dev/null || ulimit -n 8192 2>/dev/null || true

    # Rotate logs before starting if threshold reached
    rotate_logs

    # Check for binary updates & show delta over release version
    check_sushi_binary

    # Resolve latest complete model from models directory
    if ! resolve_latest_model; then
        print_error "No complete model found in ${MODELS_DIR}."
        print_info "Run '$0 setup' to download the model first."
        exit 1
    fi

    # Check for model updates on Hugging Face & prompt
    check_and_prompt_model_update
    
    print_info "Starting Sushi server on Apple Silicon M1 Max (64 GB)..."
    print_info "Configuration:"
    echo "  Binary: ${SUSHI_BIN}"
    echo "  Host: ${HOST}"
    echo "  Port: ${PORT}"
    echo "  Model: ${MODEL_PATH}"
    echo "  Sampling Profile: ${PROFILE_NAME}"
    echo "  Temperature: ${TEMP}"
    echo "  Top P: ${TOP_P}"
    echo "  Top K: ${TOP_K}"
    echo "  Min P: ${MIN_P}"
    echo "  Presence penalty: ${PRESENCE_PENALTY}"
    echo "  Repetition penalty: ${REPEAT_PENALTY}"
    echo "  Frequency penalty: ${FREQUENCY_PENALTY}"
    echo "  Context: ${CTX_SIZE} tokens"
    echo "  Max concurrent: ${MAX_CONCURRENT}"
    echo "  Wired margin: ${WIRED_MARGIN_GIB} GiB"
    echo "  Prefill decode share: ${PREFILL_DECODE_SHARE}"
    echo "  Reasoning effort: ${REASONING_EFFORT}"
    echo "  Preserve thinking: ${PRESERVE_THINKING}"
    echo "  Prefill chunk: ${PREFILL_CHUNK} tokens"
    echo "  MTP typical: ${MTP_TYPICAL}"
    echo "  GPU warm: ${GPU_WARM_SECS} s"
    echo "  Prefix cache: RAM=${PREFIX_CACHE_MEM}, SSD=${PREFIX_CACHE_DISK}, entries=${PREFIX_CACHE_ENTRIES}"
    echo "  Tokenize cache: ${TOKENIZE_CACHE_ENTRIES} entries"
    echo "  Timeout: ${TIMEOUT} s"
    echo "  Prometheus Metrics: http://${HOST}:${PORT}/metrics (enabled=${METRICS_ENABLED})"
    if [ -n "${API_KEY}" ]; then
        echo "  API Authentication: enabled (strict=${API_KEY_STRICT})"
    else
        echo "  API Authentication: disabled"
    fi
    echo "  Log: ${LOG_FILE}"
    
    # Use taskpolicy -a on macOS to lock inference threads to performance cores with user-active QoS
    local launcher=()
    if command -v taskpolicy >/dev/null 2>&1; then
        launcher=(taskpolicy -a)
        print_info "Process priority: pinned to high-performance cores (taskpolicy -a)"
    fi
    
    local chunk_args=()
    if [ -n "${PREFILL_CHUNK}" ] && [ "${PREFILL_CHUNK}" != "auto" ]; then
        chunk_args=(--prefill-chunk "${PREFILL_CHUNK}")
    fi

    local extra_args=()
    if [ -n "${GPU_WARM_SECS}" ] && [ "${GPU_WARM_SECS}" != "0" ]; then
        extra_args+=(--gpu-warm-secs "${GPU_WARM_SECS}")
    fi
    if [ -n "${REASONING_EFFORT}" ]; then
        extra_args+=(--think "${REASONING_EFFORT}")
    fi

    local prod_args=()
    if [ "${METRICS_ENABLED}" = "true" ]; then
        prod_args+=(--metrics)
    fi
    if [ -n "${TIMEOUT}" ] && [ "${TIMEOUT}" != "0" ]; then
        prod_args+=(--timeout "${TIMEOUT}")
    fi
    if [ -n "${API_KEY}" ]; then
        export SUSHI_API_KEY="${API_KEY}"
        prod_args+=(--api-key-env SUSHI_API_KEY)
        if [ "${API_KEY_STRICT}" = "true" ]; then
            prod_args+=(--api-key-strict)
        fi
    fi
    
    # Start the server in background, preserving startup logs in LOG_FILE
    nohup "${launcher[@]}" "${SUSHI_BIN}" serve \
        --model "${MODEL_PATH}" \
        --host "${HOST}" \
        --port "${PORT}" \
        --mtp \
        --mtp-min-depth "${MTP_MIN_DEPTH}" \
        --mtp-max-depth "${MTP_MAX_DEPTH}" \
        --kv-quant 4 \
        --mtp-head-kv-quant \
        --skip-mem-preflight \
        --ctx-size "${CTX_SIZE}" \
        --max-tokens "${MAX_TOKENS}" \
        --preserve-thinking "${PRESERVE_THINKING}" \
        --prefix-cache-disk "${PREFIX_CACHE_DISK}" \
        --prefix-cache-entries "${PREFIX_CACHE_ENTRIES}" \
        --prefix-cache-mem "${PREFIX_CACHE_MEM}" \
        --wired-margin-gib "${WIRED_MARGIN_GIB}" \
        --prefill-decode-share "${PREFILL_DECODE_SHARE}" \
        --no-update-check \
        "${chunk_args[@]}" \
        "${extra_args[@]}" \
        "${prod_args[@]}" \
        --temp "${TEMP}" \
        --top-p "${TOP_P}" \
        --top-k "${TOP_K}" \
        --max-concurrent "${MAX_CONCURRENT}" \
        --mtp-typical "${MTP_TYPICAL}" \
        --ssm-checkpoint-stride "${SSM_CHECKPOINT_STRIDE}" \
        --tokenize-cache-entries "${TOKENIZE_CACHE_ENTRIES}" \
        --log-level info \
        --log-file "${LOG_FILE}" \
        >> "${LOGS_DIR}/sushi-console.log" 2>&1 &
    
    NEW_PID=$!
    echo "${NEW_PID}" > "${PID_FILE}"
    
    # Wait for server to start
    print_info "Waiting for server to start (this may take 30-60 seconds)..."
    local connect_host="$([ "${HOST}" = "0.0.0.0" ] && echo "127.0.0.1" || echo "${HOST}")"
    for i in {1..120}; do
        if curl -sf "http://${connect_host}:${PORT}/health" > /dev/null 2>&1; then
            print_success "Sushi server started successfully (PID: ${NEW_PID})"
            echo ""
            echo -e "${GREEN}Server is ready on port ${PORT}!${NC}"
            echo "Local API endpoint:   http://127.0.0.1:${PORT}/v1/chat/completions"
            echo "Network API endpoint: http://${HOST}:${PORT}/v1/chat/completions"
            echo "Prometheus metrics:   http://${HOST}:${PORT}/metrics"
            echo "Health check:         curl http://127.0.0.1:${PORT}/health"
            return 0
        fi
        if [ $((i % 10)) -eq 0 ]; then
            echo -n "."
        fi
        sleep 1
    done
    
    print_error "Server failed to start within 120 seconds"
    print_info "Check logs: tail -n 50 ${LOG_FILE}"
    exit 1
}

stop_server() {
    # If managed by launchd, unload the service to stop it
    if command -v launchctl >/dev/null 2>&1 && launchctl list 2>/dev/null | grep -q "${SERVICE_LABEL}"; then
        print_info "Stopping macOS launchd service (${SERVICE_LABEL})..."
        launchctl bootout "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null || launchctl unload "${PLIST_PATH}" 2>/dev/null || true
    fi

    if [ ! -f "${PID_FILE}" ]; then
        print_warning "No PID file found. Sushi may not be running."
        return 0
    fi
    
    PID=$(cat "${PID_FILE}" 2>/dev/null || true)
    
    if [ -z "${PID}" ] || ! kill -0 "${PID}" 2>/dev/null; then
        print_warning "Sushi is not running (PID '${PID}' not found)"
        rm -f "${PID_FILE}"
        return 0
    fi
    
    print_info "Stopping Sushi server (PID: ${PID})..."
    kill -TERM "${PID}" 2>/dev/null || true
    
    # Wait for graceful shutdown
    for i in {1..30}; do
        if ! kill -0 "${PID}" 2>/dev/null; then
            rm -f "${PID_FILE}"
            print_success "Sushi server stopped"
            return 0
        fi
        sleep 1
    done
    
    print_warning "Server did not stop gracefully, forcing..."
    kill -9 "${PID}" 2>/dev/null || true
    rm -f "${PID_FILE}"
    print_success "Sushi server stopped"
}

status() {
    if check_running; then
        PID=$(cat "${PID_FILE}")
        print_success "Sushi is running (PID: ${PID})"
        echo ""
        echo "Server info:"
        local connect_host="$([ "${HOST}" = "0.0.0.0" ] && echo "127.0.0.1" || echo "${HOST}")"
        local auth_header=()
        if [ -n "${API_KEY}" ]; then
            auth_header=(-H "Authorization: Bearer ${API_KEY}")
        fi
        if command -v jq &>/dev/null; then
            curl -s "${auth_header[@]}" "http://${connect_host}:${PORT}/health" | jq . 2>/dev/null || echo "  (Unable to fetch health status)"
        else
            curl -s "${auth_header[@]}" "http://${connect_host}:${PORT}/health" || echo "  (Unable to fetch health status)"
        fi
        echo ""
        echo "Recent logs:"
        tail -n 10 "${LOG_FILE}" 2>/dev/null || echo "  (No logs yet)"
    else
        print_warning "Sushi is not running"
    fi
}

show_logs() {
    if [ -f "${LOG_FILE}" ]; then
        print_info "Showing last 50 lines of ${LOG_FILE}..."
        tail -n 50 "${LOG_FILE}"
    else
        print_error "Log file not found: ${LOG_FILE}"
    fi
}

test_api() {
    if ! check_running; then
        print_error "Sushi is not running"
        return 1
    fi
    
    print_info "Testing API endpoint..."
    local connect_host="$([ "${HOST}" = "0.0.0.0" ] && echo "127.0.0.1" || echo "${HOST}")"
    local auth_header=()
    if [ -n "${API_KEY}" ]; then
        auth_header=(-H "Authorization: Bearer ${API_KEY}")
    fi
    
    RESPONSE=$(curl -s -X POST "http://${connect_host}:${PORT}/v1/chat/completions" \
        "${auth_header[@]}" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${MODEL_NAME:-Qwen3.8-Flash-Next}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Hello, what is 2+2?\"}],
            \"max_tokens\": 50,
            \"temperature\": ${TEMP},
            \"top_p\": ${TOP_P},
            \"top_k\": ${TOP_K},
            \"min_p\": ${MIN_P},
            \"presence_penalty\": ${PRESENCE_PENALTY},
            \"repeat_penalty\": ${REPEAT_PENALTY},
            \"repetition_penalty\": ${REPEAT_PENALTY},
            \"frequency_penalty\": ${FREQUENCY_PENALTY},
            \"reasoning_effort\": \"${REASONING_EFFORT}\"
        }")
    
    if echo "${RESPONSE}" | grep -q "content"; then
        print_success "API test passed!"
        echo ""
        if command -v jq &>/dev/null; then
            echo "${RESPONSE}" | jq '.choices[0].message.content' 2>/dev/null || echo "${RESPONSE}"
        else
            echo "${RESPONSE}"
        fi
    else
        print_error "API test failed"
        echo "${RESPONSE}"
        return 1
    fi
}

show_help() {
    cat << EOF
${BLUE}Sushi LLM Server Manager (Apple Silicon M1 Max 64 GB)${NC}

Usage: $0 <command>

Core Lifecycle Commands:
  ${GREEN}setup${NC}              - Complete setup (model download, GPU wired limit, binary verification)
  ${GREEN}start-service${NC}      - Start Sushi under macOS launchd supervision (auto-restarts on exit/crash)
  ${GREEN}stop-service${NC}       - Stop launchd supervised server
  ${GREEN}restart-service${NC}    - Restart launchd supervised server
  ${GREEN}start${NC}              - Start Sushi server standalone in background
  ${GREEN}stop${NC}               - Stop Sushi server
  ${GREEN}restart${NC}            - Restart Sushi server (auto-detects launchd supervision)
  ${GREEN}status${NC}             - Show server status and health check

Binary Build & Version Switching Options:
  ${GREEN}use-release${NC}         - Switch / Rollback to official GitHub release binary (v1.1.1)
  ${GREEN}use-main${NC}            - Switch to bleeding-edge 'main' branch build (rebuilds if needed)
  ${GREEN}build${NC}               - Fetch latest commits from upstream main, recompile ReleaseFast & deploy
  ${GREEN}check-updates${NC}       - Compare installed binary vs GitHub releases vs upstream git main
  ${GREEN}use-prebuilt${NC}        - Alias for use-release
  ${GREEN}use-source${NC}          - Alias for use-main

Monitoring & Maintenance:
  ${GREEN}metrics${NC}            - Fetch Prometheus metrics (/metrics or /metrics.json with --json)
  ${GREEN}logs${NC}               - Show recent server logs
  ${GREEN}rotate-logs${NC}        - Rotate logs exceeding ${LOG_MAX_MB}MB
  ${GREEN}test${NC}               - Test API endpoint with a sample inference query

Service Management:
  ${GREEN}install-service${NC}    - Generate macOS launchd LaunchAgent (${SERVICE_LABEL})
  ${GREEN}uninstall-service${NC}  - Unload and remove macOS launchd LaunchAgent
  ${GREEN}service-status${NC}     - Check macOS launchd service registration status
  ${GREEN}run-service${NC}        - Run server in foreground under launchd supervision
  ${GREEN}help${NC}               - Show this help message

Examples:
  # Inspect updates & upstream delta (release vs main branch)
  $0 check-updates

  # Rollback to official GitHub release binary (e.g. v1.1.1)
  $0 use-release

  # Switch to latest main branch build
  $0 use-main

  # Build & merge latest from upstream main
  $0 build

  # Start as supervised daemon (restarts automatically if stopped or killed)
  $0 start-service

  # Check status & health
  $0 status

  # Fetch Prometheus metrics
  $0 metrics

  # Follow logs in real-time
  tail -f ${LOG_FILE}

  # Stop the server
  $0 stop

Configuration:
  Hardware Profile: Apple Silicon M1 Max (64 GB)
  Binary: ${SUSHI_BIN:-auto-detected / latest}
  Endpoint: http://${HOST}:${PORT} (network access enabled)
  Metrics endpoint: http://${HOST}:${PORT}/metrics (Prometheus /metrics & /metrics.json)
  Models directory: ${MODELS_DIR}
  Model: ${MODEL_PATH:-auto-detected latest from ${MODELS_DIR}}
  Sampling: ${PROFILE_NAME} (temp=${TEMP}, top_p=${TOP_P}, top_k=${TOP_K}, min_p=${MIN_P}, presence_penalty=${PRESENCE_PENALTY}, repetition_penalty=${REPEAT_PENALTY})
  Reasoning effort: ${REASONING_EFFORT}
  Preserve thinking: ${PRESERVE_THINKING}
  Performance: prefill_chunk=${PREFILL_CHUNK}, ssm_stride=${SSM_CHECKPOINT_STRIDE}, mtp_min_depth=${MTP_MIN_DEPTH}, mtp_max_depth=${MTP_MAX_DEPTH}, mtp_typical=${MTP_TYPICAL}
  Prefix cache: RAM=${PREFIX_CACHE_MEM}, SSD=${PREFIX_CACHE_DISK}, entries=${PREFIX_CACHE_ENTRIES}
  Production: timeout=${TIMEOUT}s, metrics=${METRICS_ENABLED}, max_log=${LOG_MAX_MB}MB
  Log file: ${LOG_FILE}
  PID file: ${PID_FILE}
  Launchd plist: ${PLIST_PATH}

For more info: https://github.com/beamivalice/sushi
EOF
}

# ============================================================================
# MAIN
# ============================================================================

COMMAND="${1:-help}"

case "${COMMAND}" in
    setup)
        print_info "Running Sushi setup for M1 Max 64 GB..."
        check_sushi_binary
        setup_directories
        set_gpu_memory_limit
        download_model
        print_success "Setup complete! Run '$0 start-service' to start the server."
        ;;
    start)
        start_server
        ;;
    start-service)
        start_service
        ;;
    stop)
        stop_server
        ;;
    stop-service)
        stop_service
        ;;
    restart)
        if command -v launchctl >/dev/null 2>&1 && launchctl list 2>/dev/null | grep -q "${SERVICE_LABEL}"; then
            restart_service
        else
            stop_server
            sleep 2
            start_server
        fi
        ;;
    restart-service)
        restart_service
        ;;
    status)
        status
        ;;
    build|build-main)
        build_and_deploy_from_source
        ;;
    check-updates|check-upstream|delta)
        check_all_updates
        ;;
    use-release|rollback-release|use-prebuilt)
        switch_to_release_binary
        ;;
    use-main|use-source)
        switch_to_main_binary "${2:-}"
        ;;
    metrics)
        query_metrics "${2:-}"
        ;;
    logs)
        show_logs
        ;;
    rotate-logs)
        rotate_logs
        ;;
    test)
        test_api
        ;;
    install-service)
        install_service
        ;;
    uninstall-service)
        uninstall_service
        ;;
    service-status)
        service_status
        ;;
    run-service)
        run_service
        ;;
    help)
        show_help
        ;;
    *)
        print_error "Unknown command: ${COMMAND}"
        show_help
        exit 1
        ;;
esac
