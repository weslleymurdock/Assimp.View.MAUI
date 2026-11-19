#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Keep tool output deterministic and English for local runs and CI logs.
export LANG='en_US.UTF-8'
export LANGUAGE='en_US:en'
if locale -a 2>/dev/null | grep -Eiq '^en_US(\.utf-?8)?$'; then
    export LC_ALL='en_US.UTF-8'
elif locale -a 2>/dev/null | grep -Eiq '^C\.UTF-8$'; then
    export LC_ALL='C.UTF-8'
else
    export LC_ALL='C'
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

die() {
    if declare -F progress_hide >/dev/null 2>&1; then progress_hide; fi
    printf 'build_android.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: build_android.sh [options]

Builds the reusable Assimp View library and SWIG C# bindings in an isolated
temporary directory.  With no --abi/--rid option all Android ABIs are built.

Options:
  --abi <abi> [...]        One or more: armeabi-v7a, arm64-v8a, x86, x86_64
  --rid <rid> [...]        One or more: android-arm, android-arm64, android-x86, android-x86_64
  --ssh <user@host>        Build on a Linux host and copy results back
  --output-root <path>     Repository/output root; defaults to this repository
  --vcpkg-root <path>      Existing vcpkg checkout
  --ndk-version <version>  Android NDK version (default: 26.1.10909125)
  --api <number>           Minimum Android API (default: 24)
  --jobs <number>          Parallel build jobs
  --log-level <level>      off, error, warn, info, debug or trace (default: off)
  --progress <mode>        auto, always or never (default: auto)
  --cache-root <path>      Persistent dependency cache root
  --skip-install           Reuse preinstalled host/SDK/vcpkg dependencies
  -h, --help               Show this help
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_swig() {
    local version_text version major minor patch
    version_text="$(swig -version 2>&1)"
    if [[ "$version_text" =~ SWIG[[:space:]]Version[[:space:]]([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        patch="${BASH_REMATCH[3]}"
        version="$major.$minor.$patch"
    else
        die 'could not determine SWIG version'
    fi
    if (( major < 4 || (major == 4 && minor < 3) )); then
        die "SWIG $version is too old; SWIG >= 4.3.0 is required for C# Doxygen comments"
    fi
    local probe_root="$JOB_ROOT/swig-doxygen-probe"
    mkdir -p "$probe_root/csharp"
    cat > "$probe_root/probe.h" <<'EOF'
#pragma once

/** @brief Confirms that SWIG can translate Doxygen comments for C#. */
class AssimpViewDoxygenProbeClass {
public:
    /** @brief Returns a value from the Doxygen validation probe. */
    int Value() const;
};
EOF
    cat > "$probe_root/probe.i" <<'EOF'
%module AssimpViewDoxygenProbeModule
%{
#include "probe.h"
%}
%include "probe.h"
EOF
    if ! run_logged 'SWIG C# Doxygen probe' swig -c++ -csharp -doxygen \
        -namespace Assimp.View.Maui \
        -I"$probe_root" \
        -outdir "$probe_root/csharp" \
        -o "$probe_root/probe.cxx" \
        "$probe_root/probe.i"; then
        die "SWIG $version failed the C# Doxygen probe"
    fi
    compgen -G "$probe_root/csharp/*.cs" >/dev/null || die "SWIG $version did not generate C# output for the Doxygen probe"
    progress_log "using SWIG $version with C# Doxygen support"
}

normalize_rid() {
    case "$1" in
        armeabi-v7a|android-arm) printf '%s\n' android-arm ;;
        arm64-v8a|android-arm64) printf '%s\n' android-arm64 ;;
        x86|android-x86) printf '%s\n' android-x86 ;;
        x86_64|android-x86_64) printf '%s\n' android-x86_64 ;;
        *) die "invalid Android ABI/RID '$1'" ;;
    esac
}

android_abi() {
    case "$1" in
        android-arm) printf '%s\n' armeabi-v7a ;;
        android-arm64) printf '%s\n' arm64-v8a ;;
        android-x86) printf '%s\n' x86 ;;
        android-x86_64) printf '%s\n' x86_64 ;;
        *) die "unsupported Android RID '$1'" ;;
    esac
}

vcpkg_triplet() {
    case "$1" in
        android-arm) printf '%s\n' assimpview-arm-android ;;
        android-arm64) printf '%s\n' assimpview-arm64-android ;;
        android-x86) printf '%s\n' assimpview-x86-android ;;
        android-x86_64) printf '%s\n' assimpview-x64-android ;;
        *) die "unsupported Android RID '$1'" ;;
    esac
}

write_android_triplet() {
    local triplet="$1"
    local rid="$2"
    local abi="$3"
    local architecture host_triplet
    case "$rid" in
        android-arm) architecture=arm; host_triplet=armv7a-linux-androideabi ;;
        android-arm64) architecture=arm64; host_triplet=aarch64-linux-android ;;
        android-x86) architecture=x86; host_triplet=i686-linux-android ;;
        android-x86_64) architecture=x64; host_triplet=x86_64-linux-android ;;
        *) die "unsupported Android RID '$rid'" ;;
    esac
    mkdir -p "$JOB_ROOT/triplets"
    cat > "$JOB_ROOT/triplets/$triplet.cmake" <<EOF
set(VCPKG_TARGET_ARCHITECTURE $architecture)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_CMAKE_SYSTEM_VERSION $ANDROID_API)
set(VCPKG_MAKE_BUILD_TRIPLET "--host=$host_triplet")
set(VCPKG_CMAKE_CONFIGURE_OPTIONS
    "-DANDROID_ABI=$abi"
    "-DANDROID_PLATFORM=android-$ANDROID_API"
    "-DANDROID_NDK=$ANDROID_NDK_HOME"
    "-DANDROID_NDK_HOME=$ANDROID_NDK_HOME"
    "-DANDROID_NDK_ROOT=$ANDROID_NDK_HOME")
EOF
}

ABIS=()
OUTPUT_ROOT="$REPO_ROOT"
SSH_TARGET=""
REMOTE_BUILD=false
REQUESTED_VCPKG_ROOT="${VCPKG_ROOT:-}"
CACHE_ROOT_EXPLICIT=false
NDK_VERSION="${ANDROID_NDK_VERSION:-26.1.10909125}"
ANDROID_API="${ANDROID_MIN_SDK_VERSION:-24}"
JOBS="${CMAKE_BUILD_PARALLEL_LEVEL:-}"
SKIP_INSTALL=false
LOG_LEVEL=off
PROGRESS_MODE=auto
CACHE_ROOT="${ASSIMP_VIEW_MAUI_DEPS_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/assimp-view-maui}"

normalize_log_level() {
    case "$1" in
        off|error|warn|info|debug|trace) printf '%s\n' "$1" ;;
        *) die "invalid log level '$1' (use off, error, warn, info, debug or trace)" ;;
    esac
}

append_abi_values() {
    local value part
    local parts=()
    IFS=',' read -r -a parts <<< "$1"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || die 'empty Android ABI/RID value'
        ABIS+=("$(normalize_rid "$part")")
    done
}

while (($# > 0)); do
    case "$1" in
        --abi|--rid)
            option="$1"
            shift
            (($# > 0)) || die "$option requires at least one value"
            value_count=0
            while (($# > 0)) && [[ "$1" != -* ]]; do
                append_abi_values "$1"
                value_count=$((value_count + 1))
                shift
            done
            ((value_count > 0)) || die "$option requires at least one value"
            ;;
        --output-root)
            (($# >= 2)) || die "$1 requires a value"
            OUTPUT_ROOT="$(cd -- "$2" 2>/dev/null && pwd || true)"
            [[ -n "$OUTPUT_ROOT" ]] || OUTPUT_ROOT="$2"
            shift 2
            ;;
        --ssh)
            (($# >= 2)) || die "$1 requires a value"
            SSH_TARGET="$2"
            shift 2
            ;;
        --remote-build)
            REMOTE_BUILD=true
            shift
            ;;
        --vcpkg-root)
            (($# >= 2)) || die "$1 requires a value"
            REQUESTED_VCPKG_ROOT="$2"
            shift 2
            ;;
        --ndk-version)
            (($# >= 2)) || die "$1 requires a value"
            NDK_VERSION="$2"
            shift 2
            ;;
        --api)
            (($# >= 2)) || die "$1 requires a value"
            ANDROID_API="$2"
            shift 2
            ;;
        --jobs)
            (($# >= 2)) || die "$1 requires a value"
            JOBS="$2"
            shift 2
            ;;
        --log-level)
            (($# >= 2)) || die "$1 requires a value"
            LOG_LEVEL="$(normalize_log_level "$2")"
            shift 2
            ;;
        --log-level=*)
            LOG_LEVEL="$(normalize_log_level "${1#*=}")"
            shift
            ;;
        --progress)
            (($# >= 2)) || die "$1 requires a value"
            PROGRESS_MODE="$2"
            shift 2
            ;;
        --progress=*)
            PROGRESS_MODE="${1#*=}"
            shift
            ;;
        --cache-root)
            (($# >= 2)) || die "$1 requires a value"
            CACHE_ROOT="$2"
            CACHE_ROOT_EXPLICIT=true
            shift 2
            ;;
        --cache-root=*)
            CACHE_ROOT="${1#*=}"
            CACHE_ROOT_EXPLICIT=true
            shift
            ;;
        --skip-install)
            SKIP_INSTALL=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option '$1' (use --help)"
            ;;
    esac
done

if ((${#ABIS[@]} == 0)); then
    ABIS=(android-arm android-arm64 android-x86 android-x86_64)
fi
UNIQUE_ABIS=()
for rid in "${ABIS[@]}"; do
    duplicate=false
    if ((${#UNIQUE_ABIS[@]} > 0)); then
        for unique_rid in "${UNIQUE_ABIS[@]}"; do
            if [[ "$unique_rid" == "$rid" ]]; then
                duplicate=true
                break
            fi
        done
    fi
    if [[ "$duplicate" == false ]]; then
        UNIQUE_ABIS+=("$rid")
    fi
done
ABIS=("${UNIQUE_ABIS[@]}")

if [[ -z "$JOBS" ]]; then
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
[[ "$ANDROID_API" =~ ^[0-9]+$ ]] || die "--api must be an integer"

if [[ -n "$SSH_TARGET" && "$REMOTE_BUILD" == false ]]; then
    require_command ssh
    require_command scp
    require_command tar

    [[ -f "$REPO_ROOT/swig/AssimpViewBridge.h" ]] || die "SWIG bridge source not found: $REPO_ROOT/swig/AssimpViewBridge.h"
    [[ -f "$REPO_ROOT/swig/AssimpViewBridge.cpp" ]] || die "SWIG bridge source not found: $REPO_ROOT/swig/AssimpViewBridge.cpp"
    [[ -f "$REPO_ROOT/swig/assimpview.i" ]] || die "SWIG interface not found: $REPO_ROOT/swig/assimpview.i"

    LOCAL_JOB="$(mktemp -d "${TMPDIR:-/tmp}/assimp-view-maui-android-ssh.XXXXXX")"
    cleanup_remote() { rm -rf -- "$LOCAL_JOB"; }
    trap cleanup_remote EXIT

    tar -czf "$LOCAL_JOB/source.tar.gz" \
        --exclude='.git' --exclude='*/.git/*' \
        -C "$REPO_ROOT" \
        lib/assimp_view/src \
        lib/assimp_view/contrib/osre \
        src/Assimp.View.Maui \
        swig \
        scripts/build_android.sh

    remote_dir="$(ssh "$SSH_TARGET" 'mktemp -d /tmp/assimp-view-maui-android-ssh.XXXXXX')"
    [[ -n "$remote_dir" ]] || die 'remote temporary directory was not created'
    cleanup_remote_with_ssh() {
        ssh "$SSH_TARGET" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        rm -rf -- "$LOCAL_JOB"
    }
    trap cleanup_remote_with_ssh EXIT

    scp "$LOCAL_JOB/source.tar.gz" "$SSH_TARGET:$remote_dir/source.tar.gz"
    ssh "$SSH_TARGET" "cd '$remote_dir' && mkdir source && tar -xzf source.tar.gz -C source"

    remote_args=(--remote-build --output-root "$remote_dir/output" --ndk-version "$NDK_VERSION" --api "$ANDROID_API" --jobs "$JOBS" --log-level "$LOG_LEVEL" --progress "$PROGRESS_MODE")
    [[ "$CACHE_ROOT_EXPLICIT" == true ]] && remote_args+=(--cache-root "$CACHE_ROOT")
    for rid in "${ABIS[@]}"; do
        remote_args+=(--rid "$rid")
    done
    [[ "$SKIP_INSTALL" == true ]] && remote_args+=(--skip-install)

    remote_command="cd '$remote_dir/source' && bash scripts/build_android.sh"
    for ((i = 0; i < ${#remote_args[@]}; i++)); do
        remote_command+=" '${remote_args[$i]}'"
    done
    ssh "$SSH_TARGET" "$remote_command"
    ssh "$SSH_TARGET" "tar -czf '$remote_dir/result.tar.gz' -C '$remote_dir/output' src/Assimp.View.Maui/Platforms"
    scp "$SSH_TARGET:$remote_dir/result.tar.gz" "$LOCAL_JOB/result.tar.gz"
    mkdir -p "$OUTPUT_ROOT"
    tar -xzf "$LOCAL_JOB/result.tar.gz" -C "$OUTPUT_ROOT"
    printf 'Android build completed on %s and copied to %s\n' "$SSH_TARGET" "$OUTPUT_ROOT"
    exit 0
fi

JOB_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/assimp-view-maui-android.XXXXXX")"
LOCK_PATH=""

cleanup() {
    progress_finish
    if [[ -n "$LOCK_PATH" ]]; then
        rmdir "$LOCK_PATH" 2>/dev/null || true
    fi
    rm -rf -- "$JOB_ROOT"
}
trap cleanup EXIT

COMMAND_LOG="$JOB_ROOT/commands.log"
touch "$COMMAND_LOG"

run_logged() {
    local label="$1"
    shift
    local status

    if [[ "$LOG_LEVEL" != off ]]; then
        if [[ "$LOG_LEVEL" == debug || "$LOG_LEVEL" == trace ]]; then
            local command_line
            printf -v command_line '%q ' "$@"
            progress_log "[debug] $label: $command_line"
        fi
        set +e
        "$@" 2>&1 | stream_logged_output
        status=${PIPESTATUS[0]}
        set -e
        return "$status"
    fi

    if "$@" >>"$COMMAND_LOG" 2>&1; then
        return 0
    else
        status=$?
        progress_hide
        printf '[error] %s failed; command log follows:\n' "$label" >&2
        tail -n 200 "$COMMAND_LOG" >&2 || true
        return "$status"
    fi
}

PROGRESS_ENABLED=false
PROGRESS_COMPLETED=0
PROGRESS_TOTAL=0
PROGRESS_FRAME=0

progress_init() {
    PROGRESS_TOTAL="$1"
    case "$PROGRESS_MODE" in
        always) PROGRESS_ENABLED=true ;;
        never) PROGRESS_ENABLED=false ;;
        auto) [[ -t 2 && "${TERM:-dumb}" != dumb ]] && PROGRESS_ENABLED=true || PROGRESS_ENABLED=false ;;
        *) die "invalid progress mode '$PROGRESS_MODE' (use auto, always or never)" ;;
    esac
}

progress_draw() {
    local label="$1"
    local completed="$2"
    local total="$3"
    local width=28
    local filled=0
    local percent=0
    local i red green blue

    [[ "$PROGRESS_ENABLED" == true ]] || return 0
    if (( total > 0 )); then
        percent=$((completed * 100 / total))
        filled=$((completed * width / total))
    else
        filled=$((PROGRESS_FRAME % (width + 1)))
        PROGRESS_FRAME=$((PROGRESS_FRAME + 1))
    fi

    printf '\r\033[2K\033[38;2;99;102;241m[%3d%%]\033[0m ' "$percent" >&2
    for ((i = 0; i < width; i++)); do
        if (( i < filled )); then
            red=$((79 + i * 45 / width))
            green=$((70 - i * 12 / width))
            blue=$((229 + i * 8 / width))
            printf '\033[38;2;%d;%d;%dm━\033[0m' "$red" "$green" "$blue" >&2
        else
            printf '\033[38;2;55;48;163m─\033[0m' >&2
        fi
    done
    printf ' %s' "$label" >&2
}

progress_hide() {
    if [[ "$PROGRESS_ENABLED" == true ]]; then
        printf '\r\033[2K' >&2
    fi
}

progress_log() {
    progress_hide
    printf '%s\n' "$1" >&2
    progress_draw "${PROGRESS_LABEL:-}" "$PROGRESS_COMPLETED" "$PROGRESS_TOTAL"
}

stream_logged_output() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        progress_log "$line"
    done
}

progress_update() {
    PROGRESS_COMPLETED=$((PROGRESS_COMPLETED + 1))
    PROGRESS_LABEL="$1"
    progress_draw "$1" "$PROGRESS_COMPLETED" "$PROGRESS_TOTAL"
}

progress_finish() {
    if [[ "$PROGRESS_ENABLED" == true ]]; then
        printf '\n' >&2
        PROGRESS_ENABLED=false
    fi
}

validate_android_host() {
    [[ "$(uname -s)" == Linux ]] || die 'Android native builds require a Linux host or WSL'
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) die "Android host architecture $(uname -m) is unsupported; use Linux x86_64" ;;
    esac
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13* ]]; then
            progress_log 'Debian 13 host detected; Android toolchain is supported'
        else
            progress_log "Linux host detected: ${PRETTY_NAME:-unknown distribution}"
        fi
    fi
}

set_android_ndk_environment() {
    local ndk_root="$1"
    [[ -f "$ndk_root/build/cmake/android.toolchain.cmake" ]] || die "Android NDK CMake toolchain was not found at $ndk_root/build/cmake/android.toolchain.cmake"
    [[ -x "$ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++" ]] || die "Android NDK Linux x86_64 Clang was not found at $ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++"
    export ANDROID_NDK_HOME="$ndk_root"
    export ANDROID_NDK_ROOT="$ndk_root"
    export ANDROID_NDK="$ndk_root"
}

prepare_dependency_cache() {
    mkdir -p "$CACHE_ROOT/downloads" "$CACHE_ROOT/binary-cache"
    export VCPKG_DOWNLOADS="$CACHE_ROOT/downloads"
    export VCPKG_DEFAULT_BINARY_CACHE="$CACHE_ROOT/binary-cache"
}

source_fingerprint() {
    local source_root="$1"
    local revision dirty untracked
    revision="$(git -C "$source_root" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$revision" ]]; then
        dirty="$(git -C "$source_root" diff --binary HEAD 2>/dev/null | sha256sum | awk '{print $1}')"
        untracked="$(git -C "$source_root" ls-files --others --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' file; do sha256sum "$source_root/$file"; done | sha256sum | awk '{print $1}')"
        printf '%s:%s:%s\n' "$revision" "$dirty" "$untracked"
    else
        find "$source_root" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
    fi
}

install_host_dependencies() {
    if [[ "$SKIP_INSTALL" == true ]]; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        local packages=(ca-certificates cmake ninja-build swig git curl unzip tar build-essential default-jre-headless)
        local missing=()
        local package
        for package in "${packages[@]}"; do
            dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || missing+=("$package")
        done
        if ((${#missing[@]} > 0)); then
            if [[ "$(id -u)" == 0 ]]; then
                run_logged 'apt-get update' apt-get update
                run_logged 'apt-get install' apt-get install -y "${missing[@]}"
            else
                require_command sudo
                run_logged 'sudo apt-get update' sudo apt-get update
                run_logged 'sudo apt-get install' sudo apt-get install -y "${missing[@]}"
            fi
        fi
    fi

    require_command cmake
    require_command swig
    require_command git
    require_command curl
    require_command unzip
}

ensure_android_toolchain() {
    local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${HOME}/.android-sdk}}"
    export ANDROID_SDK_ROOT="$sdk_root"
    export ANDROID_HOME="$sdk_root"
    local ndk_path="$sdk_root/ndk/$NDK_VERSION"
    local configured_ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"

    if [[ -n "$configured_ndk" ]]; then
        [[ -d "$configured_ndk" ]] || die "configured Android NDK directory does not exist: $configured_ndk"
        set_android_ndk_environment "$configured_ndk"
        return
    fi

    if [[ ! -d "$ndk_path" ]]; then
        local sdkmanager="$sdk_root/cmdline-tools/latest/bin/sdkmanager"
        if [[ ! -x "$sdkmanager" ]]; then
            mkdir -p "$sdk_root/cmdline-tools"
            local commandline_zip="$JOB_ROOT/commandlinetools-linux.zip"
            run_logged 'download Android command-line tools' curl -fsSL 'https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip' -o "$commandline_zip"
            local extract_dir="$JOB_ROOT/android-cmdline-tools"
            mkdir -p "$extract_dir"
            run_logged 'extract Android command-line tools' unzip -q -o "$commandline_zip" -d "$extract_dir"
            rm -rf -- "$sdk_root/cmdline-tools/latest"
            run_logged 'install Android command-line tools' mv "$extract_dir/cmdline-tools" "$sdk_root/cmdline-tools/latest"
            sdkmanager="$sdk_root/cmdline-tools/latest/bin/sdkmanager"
        fi
        [[ -x "$sdkmanager" ]] || die "Android sdkmanager is not executable: $sdkmanager"
        require_command java
        if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
            local java_path
            java_path="$(readlink -f "$(command -v java)")"
            export JAVA_HOME="${java_path%/bin/java}"
        fi
        set +o pipefail
        if [[ "$LOG_LEVEL" == off ]]; then
            yes | "$sdkmanager" --sdk_root="$sdk_root" --licenses >>"$COMMAND_LOG" 2>&1 || true
        else
            yes | "$sdkmanager" --sdk_root="$sdk_root" --licenses 2>&1 >&2 || true
        fi
        set -o pipefail
        run_logged 'install Android SDK/NDK packages' "$sdkmanager" --sdk_root="$sdk_root" "platform-tools" "platforms;android-$ANDROID_API" "ndk;$NDK_VERSION"
    fi

    [[ -d "$ndk_path" ]] || die "Android NDK was not installed at $ndk_path"
    set_android_ndk_environment "$ndk_path"
}

prepare_vcpkg() {
    prepare_dependency_cache
    if [[ -n "$REQUESTED_VCPKG_ROOT" && -f "$REQUESTED_VCPKG_ROOT/vcpkg" ]]; then
        printf '%s\n' "$REQUESTED_VCPKG_ROOT"
        return
    fi

    local source_root="$REQUESTED_VCPKG_ROOT"
    if [[ -z "$source_root" ]]; then
        source_root="$REPO_ROOT/lib/assimp_view/contrib/osre/contrib/vcpkg"
    fi
    [[ -d "$source_root" ]] || die "vcpkg source not found: $source_root"

    local source_hash
    source_hash="$(source_fingerprint "$source_root")"
    local cached_root="$CACHE_ROOT/vcpkg"
    local marker="$cached_root/.assimp-view-source-hash"
    if [[ -x "$cached_root/vcpkg" && -f "$marker" && "$(<"$marker")" == "$source_hash" ]]; then
        printf '%s\n' "$cached_root"
        return
    fi

    local cache_lock="$CACHE_ROOT/.vcpkg.lock"
    until mkdir "$cache_lock" 2>/dev/null; do
        if [[ -f "$cache_lock/pid" ]]; then
            local owner_pid
            owner_pid="$(<"$cache_lock/pid")"
            if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
                rm -rf -- "$cache_lock"
                continue
            fi
        fi
        sleep 0.2
    done
    printf '%s\n' "$$" > "$cache_lock/pid"
    if [[ -x "$cached_root/vcpkg" && -f "$marker" && "$(<"$marker")" == "$source_hash" ]]; then
        rm -f -- "$cache_lock/pid"
        rmdir "$cache_lock"
        printf '%s\n' "$cached_root"
        return
    fi

    local local_root="$JOB_ROOT/vcpkg-cache-staging"
    rm -rf -- "$local_root"
    mkdir -p "$local_root"
    if ! cp -a "$source_root/." "$local_root/"; then
        rm -f -- "$cache_lock/pid"
        rmdir "$cache_lock"
        die "could not stage vcpkg from $source_root"
    fi
    if [[ ! -f "$local_root/vcpkg" ]]; then
        [[ -f "$local_root/bootstrap-vcpkg.sh" ]] || { rm -f -- "$cache_lock/pid"; rmdir "$cache_lock"; die "bootstrap-vcpkg.sh not found in $source_root"; }
        if ! (cd "$local_root" && run_logged 'vcpkg bootstrap' bash ./bootstrap-vcpkg.sh -disableMetrics); then
            rm -f -- "$cache_lock/pid"
            rmdir "$cache_lock"
            die 'vcpkg bootstrap failed'
        fi
    fi
    [[ -f "$local_root/vcpkg" ]] || { rm -f -- "$cache_lock/pid"; rmdir "$cache_lock"; die 'vcpkg bootstrap failed'; }
    printf '%s\n' "$source_hash" > "$local_root/.assimp-view-source-hash"
    rm -rf -- "$cached_root"
    mv "$local_root" "$cached_root"
    rm -f -- "$cache_lock/pid"
    rmdir "$cache_lock"
    printf '%s\n' "$cached_root"
}

create_overlay() {
    local overlay="$JOB_ROOT/osre"
    mkdir -p "$overlay"
    cp -a "$REPO_ROOT/lib/assimp_view/contrib/osre/." "$overlay/"
    cat > "$overlay/vcpkg.json" <<'EOF'
{
  "dependencies": [
    "glm",
    "sdl2"
  ]
}
EOF
    mkdir -p "$JOB_ROOT/android-compat/include/GL"
    cat > "$JOB_ROOT/android-compat/include/GL/glew.h" <<'EOF'
#pragma once

#ifndef GL_GLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES 1
#endif

#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

// OSRE's OpenGL backend is shared with desktop OpenGL.  Android exposes
// OpenGL ES instead, so provide the small compile-time compatibility surface
// used by the reusable renderer.  Desktop-only operations are either mapped
// to their GLES equivalent or intentionally become no-ops.
#ifndef GL_TEXTURE_1D
#define GL_TEXTURE_1D GL_TEXTURE_2D
#endif
#ifndef GL_POINT
#define GL_POINT 0x1B00
#endif
#ifndef GL_LINE
#define GL_LINE 0x1B01
#endif
#ifndef GL_FILL
#define GL_FILL 0x1B02
#endif
#ifndef GL_GEOMETRY_SHADER
#define GL_GEOMETRY_SHADER 0x8DD9
#endif
#ifndef GL_TESS_EVALUATION_SHADER
#define GL_TESS_EVALUATION_SHADER 0x8E87
#endif
#ifndef GL_CONTEXT_PROFILE_MASK
#define GL_CONTEXT_PROFILE_MASK 0x9126
#endif
#ifndef GL_MAX_TEXTURE_UNITS
#define GL_MAX_TEXTURE_UNITS GL_MAX_TEXTURE_IMAGE_UNITS
#endif
#ifndef GL_MAX_TEXTURE_COORDS
#define GL_MAX_TEXTURE_COORDS GL_MAX_VERTEX_ATTRIBS
#endif
#ifndef GL_LIGHTING
#define GL_LIGHTING 0x0B50
#endif
#ifndef GL_MULTISAMPLE
#define GL_MULTISAMPLE 0x809D
#endif
#ifndef GL_CLAMP
#define GL_CLAMP GL_CLAMP_TO_EDGE
#endif
#ifndef GL_BGR_EXT
#define GL_BGR_EXT GL_RGB
#endif

static inline void glFramebufferTexture(GLenum target, GLenum attachment,
        GLuint texture, GLint level) {
    glFramebufferTexture2D(target, attachment, GL_TEXTURE_2D, texture, level);
}

static inline void glPolygonMode(GLenum, GLenum) {
    // Polygon mode is not part of OpenGL ES.  Filled rasterization is the
    // only portable GLES mode and is the default on Android.
}

#ifndef GLEW_OK
#define GLEW_OK 0
#endif

static GLboolean glewExperimental = GL_TRUE;
static inline GLenum glewInit(void) { return GLEW_OK; }
EOF
    cat > "$JOB_ROOT/android-compat/include/GL/gl.h" <<'EOF'
#pragma once

#include <GL/glew.h>
EOF
    perl -0pi -e 's/find_package\(GLEW\s+REQUIRED\)/if(NOT ANDROID)\n    find_package(GLEW REQUIRED)\n    set(OSRE_GLEW_LINK GLEW::GLEW)\nendif()/' \
        "$overlay/CMakeLists.txt"
    perl -0pi -e 's/\n    glEnable\(GL_MULTISAMPLE\);/\n#if !defined(__ANDROID__)\n    glEnable(GL_MULTISAMPLE);\n#endif/' \
        "$overlay/src/Engine/RenderBackend/OGLRenderer/OGLRenderBackend.cpp"
    perl -0pi -e 's/ENDIF\( WIN32 \)/ENDIF( WIN32 )\nif(ANDROID)\n    list(APPEND platform_libs GLESv3)\nendif()/' \
        "$overlay/src/Engine/CMakeLists.txt"
    perl -0pi -e 's/#elif defined\(__gnu_linux__\)/#elif defined(__gnu_linux__) || defined(__ANDROID__)/' \
        "$overlay/contrib/cppcore/include/cppcore/CPPCoreCommon.h"
    sed -i 's/cppcore)/$<TARGET_NAME_IF_EXISTS:cppcore>)/g' "$overlay/src/Engine/CMakeLists.txt"
    sed -i 's/target_link_libraries ( osre cppcore zlibstatic GLEW::GLEW ${platform_libs} assimp )/target_link_libraries ( osre $<TARGET_NAME_IF_EXISTS:cppcore> $<TARGET_NAME_IF_EXISTS:zlibstatic> ${OSRE_GLEW_LINK} ${platform_libs} $<TARGET_NAME_IF_EXISTS:assimp> )/' "$overlay/src/Engine/CMakeLists.txt"
    printf '%s\n' "$overlay"
}

write_bridge_sources() {
    cat > "$JOB_ROOT/AssimpViewBridge.h" <<'EOF'
#pragma once

namespace AssimpViewMaui {

class AssimpView {
public:
    /** @brief Creates a reusable Assimp View instance. */
    AssimpView();
    /** @brief Releases the native Assimp View instance. */
    ~AssimpView();

    /**
     * @brief Creates the native rendering window and graphics context.
     * @param width Initial view width in pixels.
     * @param height Initial view height in pixels.
     * @return true when the native view was initialized.
     */
    bool Initialize(int width, int height);
    /**
     * @brief Loads a 3D asset from a native URI/path.
     * @param path URI or path accepted by Assimp View.
     * @return true when the asset was loaded.
     */
    bool LoadAsset(const char *path);
    /** @brief Processes events and renders one frame. */
    bool Frame();
    /**
     * @brief Resizes the native rendering surface.
     * @param width New view width in pixels.
     * @param height New view height in pixels.
     */
    void Resize(int width, int height);
    /** @brief Releases the native rendering resources. */
    void Shutdown();
    /** @brief Reports whether an asset is currently loaded. */
    bool HasModel() const;

private:
    class Impl;
    Impl *m_impl;
};

} // namespace AssimpViewMaui
EOF

    cat > "$JOB_ROOT/AssimpViewBridge.cpp" <<'EOF'
#include "ModelLoadingApp.h"

#include "AssimpViewBridge.h"
#include "IO/Uri.h"

namespace AssimpViewMaui {

class AssimpView::Impl {
public:
    char arg0[16];
    char *argv[2];
    ModelLoadingApp app;
    bool initialized;

    Impl() : arg0{}, argv{arg0, nullptr}, app(1, argv), initialized(false) {
        arg0[0] = 'A';
        arg0[1] = 's';
        arg0[2] = 's';
        arg0[3] = 'i';
        arg0[4] = 'm';
        arg0[5] = 'p';
        arg0[6] = 'V';
        arg0[7] = 'i';
        arg0[8] = 'e';
        arg0[9] = 'w';
        arg0[10] = '\0';
    }
};

AssimpView::AssimpView() : m_impl(new Impl) {}

AssimpView::~AssimpView() {
    Shutdown();
    delete m_impl;
    m_impl = nullptr;
}

bool AssimpView::Initialize(int width, int height) {
    if (m_impl == nullptr) {
        return false;
    }
    if (m_impl->initialized) {
        return true;
    }
    m_impl->initialized = m_impl->app.initWindow(
        0, 0, static_cast<OSRE::ui32>(width), static_cast<OSRE::ui32>(height),
        "Assimp View", OSRE::App::WindowMode::Windowed,
        OSRE::App::WindowType::Root,
        OSRE::App::RenderBackendType::OpenGLRenderBackend);
    return m_impl->initialized;
}

bool AssimpView::LoadAsset(const char *path) {
    if (m_impl == nullptr || !m_impl->initialized || path == nullptr) {
        return false;
    }
    OSRE::IO::Uri uri{OSRE::String(path)};
    if (!uri.isValid()) {
        return false;
    }
    m_impl->app.importAsset(uri);
    return m_impl->app.hasModel();
}

bool AssimpView::Frame() {
    if (m_impl == nullptr || !m_impl->initialized) {
        return false;
    }
    if (!m_impl->app.handleEvents()) {
        return false;
    }
    m_impl->app.update();
    m_impl->app.requestNextFrame();
    return true;
}

void AssimpView::Resize(int width, int height) {
    if (m_impl != nullptr && m_impl->initialized) {
        m_impl->app.resize(0, 0, width, height);
    }
}

void AssimpView::Shutdown() {
    if (m_impl != nullptr && m_impl->initialized) {
        m_impl->app.destroy();
        m_impl->initialized = false;
    }
}

bool AssimpView::HasModel() const {
    return m_impl != nullptr && m_impl->app.hasModel();
}

} // namespace AssimpViewMaui
EOF

    cat > "$JOB_ROOT/assimpview.i" <<'EOF'
%module AssimpViewModule

%{
#include "AssimpViewBridge.h"
%}

%include "AssimpViewBridge.h"
EOF

    # Keep the native facade and SWIG surface in one source-controlled template.
    cp "$REPO_ROOT/swig/AssimpViewBridge.h" "$JOB_ROOT/AssimpViewBridge.h"
    cp "$REPO_ROOT/swig/AssimpViewBridge.cpp" "$JOB_ROOT/AssimpViewBridge.cpp"
    cp "$REPO_ROOT/swig/assimpview.i" "$JOB_ROOT/assimpview.i"
    perl -0pe 's/#include "ModelLoadingApp\.h"/#if defined(ASSIMP_VIEW_MODEL_LOADING_ACCESS_SHIM)\n#define protected public\n#endif\n#include "ModelLoadingApp.h"\n#if defined(ASSIMP_VIEW_MODEL_LOADING_ACCESS_SHIM)\n#undef protected\n#endif/' \
        "$REPO_ROOT/lib/assimp_view/src/ModelLoading.cpp" > "$JOB_ROOT/ModelLoading.cpp"
}

generate_bindings() {
    mkdir -p "$JOB_ROOT/swig/csharp" "$JOB_ROOT/swig/cxx"
    run_logged 'SWIG C# bindings' swig -c++ -csharp \
        -namespace Assimp.View.Maui \
        -doxygen \
        -dllimport assimpviewmaui \
        -I"$JOB_ROOT" \
        -outdir "$JOB_ROOT/swig/csharp" \
        -o "$JOB_ROOT/swig/cxx/assimpviewmaui.cxx" \
        "$JOB_ROOT/assimpview.i"
    compgen -G "$JOB_ROOT/swig/csharp/*.cs" >/dev/null || die 'SWIG did not generate C# classes'
}

write_cmake_project() {
    local overlay="$1"
    local native_out="$2"
    local build_shared="$3"
    local project="$JOB_ROOT/project"
    mkdir -p "$project"

    cat > "$project/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.21)
project(AssimpViewMaui LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${native_out}")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${native_out}")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${native_out}")
set(CMAKE_MODULE_PATH "${overlay}/contrib/assimp/cmake-modules" \${CMAKE_MODULE_PATH})
include_directories(BEFORE "${JOB_ROOT}/android-compat/include")

set(OSRE_BUILD_PLAYER OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_SAMPLES OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_ED OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_DOC OFF CACHE BOOL "" FORCE)
set(ASSIMP_BUILD_ASSIMP_TOOLS OFF CACHE BOOL "" FORCE)
set(ASSIMP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(ASSIMP_BUILD_ZLIB ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS ${build_shared} CACHE BOOL "" FORCE)

add_subdirectory("${overlay}" "\${CMAKE_BINARY_DIR}/osre" EXCLUDE_FROM_ALL)

add_library(assimpviewmaui SHARED
    "${JOB_ROOT}/ModelLoading.cpp"
    "${JOB_ROOT}/AssimpViewBridge.cpp"
    "${JOB_ROOT}/swig/cxx/assimpviewmaui.cxx")
set_source_files_properties("${JOB_ROOT}/ModelLoading.cpp" PROPERTIES
    COMPILE_DEFINITIONS ASSIMP_VIEW_MODEL_LOADING_ACCESS_SHIM)
target_include_directories(assimpviewmaui PRIVATE
    "${REPO_ROOT}/lib/assimp_view/src"
    "${overlay}/src/Engine"
    "${overlay}/include"
    "${overlay}/contrib/assimp/include"
    "${overlay}/contrib/cppcore/include"
    "${JOB_ROOT}")
target_link_libraries(assimpviewmaui PRIVATE osre)
set_target_properties(assimpviewmaui PROPERTIES
    WINDOWS_EXPORT_ALL_SYMBOLS ON
    LIBRARY_OUTPUT_DIRECTORY "${native_out}"
    ARCHIVE_OUTPUT_DIRECTORY "${native_out}"
    RUNTIME_OUTPUT_DIRECTORY "${native_out}")

foreach(_target osre cppcore assimp zlibstatic assimpviewmaui)
    if(TARGET \${_target})
        set_target_properties(\${_target} PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY "${native_out}"
            ARCHIVE_OUTPUT_DIRECTORY "${native_out}"
            RUNTIME_OUTPUT_DIRECTORY "${native_out}")
    endif()
endforeach()
EOF
}

install_atomic() {
    local source="$1"
    local destination="$2"
    local temporary="${destination}.tmp.$$.${RANDOM}"
    cp -f "$source" "$temporary"
    mv -f "$temporary" "$destination"
}

publish() {
    local rid="$1"
    local platform_root="$OUTPUT_ROOT/src/Assimp.View.Maui/Platforms/Android"
    local native_root="$platform_root/runtimes/$rid/native"
    mkdir -p "$platform_root/AssimpView" "$native_root"

    local lock_path="$platform_root/.assimp-view-publish.lock"
    until mkdir "$lock_path" 2>/dev/null; do
        sleep 0.2
    done
    LOCK_PATH="$lock_path"

    local cs
    for cs in "$JOB_ROOT/swig/csharp"/*.cs; do
        install_atomic "$cs" "$platform_root/AssimpView/$(basename "$cs")"
    done

    local native
    for native in "$JOB_ROOT/publish/$rid/native"/*; do
        [[ -f "$native" ]] || continue
        install_atomic "$native" "$native_root/$(basename "$native")"
    done

    rmdir "$LOCK_PATH"
    LOCK_PATH=""
}

progress_init $((4 + 4 * ${#ABIS[@]}))
validate_android_host
install_host_dependencies
progress_update 'host dependencies'
require_command cmake
require_command swig
validate_swig

if [[ "$SKIP_INSTALL" == false ]]; then
    ensure_android_toolchain
else
    configured_ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"
    [[ -n "$configured_ndk" ]] || die 'ANDROID_NDK_HOME, ANDROID_NDK_ROOT or ANDROID_NDK is required with --skip-install'
    set_android_ndk_environment "$configured_ndk"
fi
    progress_update 'Android SDK and NDK'

prepare_dependency_cache
VCPKG_ROOT_EFFECTIVE="$(prepare_vcpkg)"
progress_update 'vcpkg toolchain'
OVERLAY_ROOT="$(create_overlay)"
write_bridge_sources
generate_bindings
progress_update 'SWIG C# bindings'

for rid in "${ABIS[@]}"; do
    abi="$(android_abi "$rid")"
    triplet="$(vcpkg_triplet "$rid")"
    write_android_triplet "$triplet" "$rid" "$abi"
    install_root="$JOB_ROOT/vcpkg-installed/$rid"
    native_out="$JOB_ROOT/native/$rid"
    build_dir="$JOB_ROOT/build/$rid"
    mkdir -p "$native_out" "$build_dir"

    if [[ "$SKIP_INSTALL" == false ]]; then
        run_logged "vcpkg install $rid" "$VCPKG_ROOT_EFFECTIVE/vcpkg" install \
            "--triplet=$triplet" \
            "--overlay-triplets=$JOB_ROOT/triplets" \
            "--x-manifest-root=$OVERLAY_ROOT" \
            "--x-install-root=$install_root" \
            --clean-after-build
    else
        install_root="$VCPKG_ROOT_EFFECTIVE/installed"
        [[ -d "$install_root" ]] || die "--skip-install requires a populated vcpkg installed directory: $install_root"
    fi
    progress_update "vcpkg $rid"

    write_cmake_project "$OVERLAY_ROOT" "$native_out" OFF
    run_logged "CMake configure $rid" cmake -S "$JOB_ROOT/project" -B "$build_dir" -G Ninja \
        "-DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT_EFFECTIVE/scripts/buildsystems/vcpkg.cmake" \
        "-DVCPKG_CHAINLOAD_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
        "-DVCPKG_TARGET_TRIPLET=$triplet" \
        "-DVCPKG_OVERLAY_TRIPLETS=$JOB_ROOT/triplets" \
        "-DVCPKG_INSTALLED_DIR=$install_root" \
        "-DANDROID_ABI=$abi" \
        "-DANDROID_PLATFORM=android-$ANDROID_API" \
        "-DANDROID_NDK=$ANDROID_NDK_HOME" \
        "-DANDROID_NDK_HOME=$ANDROID_NDK_HOME" \
        "-DANDROID_STL=c++_shared" \
        "-DCMAKE_BUILD_TYPE=Release" \
        "-DUSE_PLATFORM=VK_USE_PLATFORM_ANDROID_KHR"
    progress_update "CMake configure $rid"
    run_logged "CMake build $rid" cmake --build "$build_dir" --config Release --parallel "$JOBS"
    progress_update "CMake build $rid"

    mkdir -p "$JOB_ROOT/publish/$rid/native"
    while IFS= read -r -d '' native; do
        case "$native" in
            */debug/*|*/vcpkg/*|*/osre/*) continue ;;
        esac
        cp -f "$native" "$JOB_ROOT/publish/$rid/native/$(basename "$native")"
    done < <(find "$JOB_ROOT" -type f -name '*.so' -print0)

    triple="$(case "$abi" in armeabi-v7a) printf '%s' arm-linux-androideabi ;; arm64-v8a) printf '%s' aarch64-linux-android ;; x86) printf '%s' i686-linux-android ;; x86_64) printf '%s' x86_64-linux-android ;; esac)"
    libcxx="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$triple/libc++_shared.so"
    [[ -f "$libcxx" ]] && cp -f "$libcxx" "$JOB_ROOT/publish/$rid/native/libc++_shared.so"

    compgen -G "$JOB_ROOT/publish/$rid/native/*.so" >/dev/null || die "no Android native libraries were generated for $rid"
    publish "$rid"
    progress_update "publish $rid"
    progress_log "built Android $rid ($abi)"
done

