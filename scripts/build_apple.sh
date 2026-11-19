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
    printf 'build_apple.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: build_apple.sh [options]

Builds one or all Apple RIDs in isolated temporary directories.  The script
can run directly on macOS or remotely through SSH from another host.

Options:
  --abi <rid/arch> [...]   One or more Apple RIDs/architectures
  --rid <rid> [...]        One or more Apple RIDs
  --ssh <user@host>        Build on a macOS host and copy results back
  --output-root <path>     Repository/output root; defaults to this repository
  --vcpkg-root <path>      Existing vcpkg checkout on the build host
  --cache-root <path>      Persistent dependency cache root
  --jobs <number>          Parallel build jobs
  --log-level <level>      off, error, warn, info, debug or trace (default: off)
  --progress <mode>        auto, always or never (default: auto)
  --skip-install           Reuse preinstalled Homebrew/vcpkg dependencies
  -h, --help               Show this help
EOF
}

die_remote() {
    printf 'build_apple.sh: %s\n' "$*" >&2
    exit 1
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
        ios-arm64|iphoneos-arm64|arm64) printf '%s\n' ios-arm64 ;;
        iossimulator-arm64|iossimulator-arm64|iphonesimulator-arm64) printf '%s\n' iossimulator-arm64 ;;
        maccatalyst-arm64|macabi-arm64) printf '%s\n' maccatalyst-arm64 ;;
        *) die "invalid Apple RID '$1'" ;;
    esac
}

ABIS=()
OUTPUT_ROOT="$REPO_ROOT"
SSH_TARGET=""
REQUESTED_VCPKG_ROOT="${VCPKG_ROOT:-}"
CACHE_ROOT_EXPLICIT=false
if [[ -n "${ASSIMP_VIEW_MAUI_DEPS_ROOT:-}" ]]; then
    CACHE_ROOT="$ASSIMP_VIEW_MAUI_DEPS_ROOT"
elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    CACHE_ROOT="$XDG_CACHE_HOME/assimp-view-maui"
else
    CACHE_ROOT="$HOME/Library/Caches/Assimp.View.Maui"
fi
JOBS="${CMAKE_BUILD_PARALLEL_LEVEL:-}"
SKIP_INSTALL=false
REMOTE_BUILD=false
LOG_LEVEL=off
PROGRESS_MODE=auto

normalize_log_level() {
    case "$1" in
        off|error|warn|info|debug|trace) printf '%s\n' "$1" ;;
        *) die "invalid log level '$1' (use off, error, warn, info, debug or trace)" ;;
    esac
}

append_apple_values() {
    local value part
    local parts=()
    IFS=',' read -r -a parts <<< "$1"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || die 'empty Apple ABI/RID value'
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
                append_apple_values "$1"
                value_count=$((value_count + 1))
                shift
            done
            ((value_count > 0)) || die "$option requires at least one value"
            ;;
        --ssh)
            (($# >= 2)) || die "$1 requires a value"
            SSH_TARGET="$2"
            shift 2
            ;;
        --output-root)
            (($# >= 2)) || die "$1 requires a value"
            OUTPUT_ROOT="$(cd -- "$2" 2>/dev/null && pwd || true)"
            [[ -n "$OUTPUT_ROOT" ]] || OUTPUT_ROOT="$2"
            shift 2
            ;;
        --vcpkg-root)
            (($# >= 2)) || die "$1 requires a value"
            REQUESTED_VCPKG_ROOT="$2"
            shift 2
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
        --skip-install)
            SKIP_INSTALL=true
            shift
            ;;
        --remote-build)
            REMOTE_BUILD=true
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
    ABIS=(ios-arm64 iossimulator-arm64 maccatalyst-arm64)
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
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '4')"
fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"

clean_published_outputs() {
    [[ -n "$OUTPUT_ROOT" && "$OUTPUT_ROOT" != / ]] || die 'refusing to clean an empty or root output path'

    local rid platform platform_root native_root clean_lock
    for rid in "${ABIS[@]}"; do
        case "$rid" in
            ios-arm64|iossimulator-arm64) platform=iOS ;;
            maccatalyst-arm64) platform=MacCatalyst ;;
            *) die "no Apple platform mapping for $rid" ;;
        esac

        platform_root="$OUTPUT_ROOT/src/Assimp.View.Maui/Platforms/$platform"
        native_root="$platform_root/runtimes/$rid/native"
        mkdir -p "$platform_root"
        clean_lock="$platform_root/.assimp-view-clean.lock"
        until mkdir "$clean_lock" 2>/dev/null; do
            sleep 0.2
        done

        # The build itself always uses a fresh JOB_ROOT. Remove only published
        # generated code/native output for the requested platform and RID;
        # dependency/download caches remain intact.
        rm -rf -- "$platform_root/AssimpView" "$native_root"
        rmdir "$clean_lock"
    done
}

if [[ -n "$SSH_TARGET" && "$REMOTE_BUILD" == false ]]; then
    clean_published_outputs
    require_command ssh
    require_command scp
    require_command tar

    [[ -f "$REPO_ROOT/swig/AssimpViewBridge.h" ]] || die "SWIG bridge source not found: $REPO_ROOT/swig/AssimpViewBridge.h"
    [[ -f "$REPO_ROOT/swig/AssimpViewBridge.cpp" ]] || die "SWIG bridge source not found: $REPO_ROOT/swig/AssimpViewBridge.cpp"
    [[ -f "$REPO_ROOT/swig/assimpview.i" ]] || die "SWIG interface not found: $REPO_ROOT/swig/assimpview.i"

    LOCAL_JOB="$(mktemp -d "${TMPDIR:-/tmp}/assimp-view-maui-ssh.XXXXXX")"
    cleanup_remote() {
        rm -rf -- "$LOCAL_JOB"
    }
    trap cleanup_remote EXIT

    tar -czf "$LOCAL_JOB/source.tar.gz" \
        --exclude='.git' --exclude='*/.git/*' \
        -C "$REPO_ROOT" \
        lib/assimp_view/src \
        lib/assimp_view/contrib/osre \
        src/Assimp.View.Maui \
        swig \
        scripts/build_apple.sh

    remote_dir="$(ssh "$SSH_TARGET" 'mktemp -d /tmp/assimp-view-maui-ssh.XXXXXX')"
    [[ -n "$remote_dir" ]] || die 'remote temporary directory was not created'
    cleanup_remote_with_ssh() {
        ssh "$SSH_TARGET" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        rm -rf -- "$LOCAL_JOB"
    }
    trap cleanup_remote_with_ssh EXIT

    scp "$LOCAL_JOB/source.tar.gz" "$SSH_TARGET:$remote_dir/source.tar.gz"
    ssh "$SSH_TARGET" "cd '$remote_dir' && mkdir source && tar -xzf source.tar.gz -C source"

    remote_args=(--remote-build --output-root "$remote_dir/output")
    for rid in "${ABIS[@]}"; do
        remote_args+=(--rid "$rid")
    done
    remote_args+=(--jobs "$JOBS")
    remote_args+=(--log-level "$LOG_LEVEL")
    remote_args+=(--progress "$PROGRESS_MODE")
    [[ "$CACHE_ROOT_EXPLICIT" == true ]] && remote_args+=(--cache-root "$CACHE_ROOT")
    [[ "$SKIP_INSTALL" == true ]] && remote_args+=(--skip-install)

    remote_command="cd '$remote_dir/source' && bash scripts/build_apple.sh"
    for ((i = 0; i < ${#remote_args[@]}; i++)); do
        remote_command+=" '${remote_args[$i]}'"
    done
    ssh "$SSH_TARGET" "$remote_command"
    ssh "$SSH_TARGET" "tar -czf '$remote_dir/result.tar.gz' -C '$remote_dir/output' src/Assimp.View.Maui/Platforms"
    scp "$SSH_TARGET:$remote_dir/result.tar.gz" "$LOCAL_JOB/result.tar.gz"
    mkdir -p "$OUTPUT_ROOT"
    tar -xzf "$LOCAL_JOB/result.tar.gz" -C "$OUTPUT_ROOT"
    printf 'Apple build completed on %s and copied to %s\n' "$SSH_TARGET" "$OUTPUT_ROOT"
    exit 0
fi

[[ "$(uname -s)" == Darwin ]] || die 'direct Apple builds require macOS; use --ssh user@mac-host from another host'

clean_published_outputs

JOB_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/assimp-view-maui-apple.XXXXXX")"
LOCK_PATH=""
cleanup() {
    local exit_status=$?
    progress_finish
    if [[ -n "$LOCK_PATH" ]]; then
        rmdir "$LOCK_PATH" 2>/dev/null || true
    fi
    if ((exit_status == 0)); then
        rm -rf -- "$JOB_ROOT"
    else
        printf 'Apple build failed; temporary logs retained at %s\n' "$JOB_ROOT" >&2
    fi
    return "$exit_status"
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
        dirty="$(git -C "$source_root" diff --binary HEAD 2>/dev/null | shasum -a 256 | awk '{print $1}')"
        untracked="$(git -C "$source_root" ls-files --others --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' file; do shasum -a 256 "$source_root/$file"; done | shasum -a 256 | awk '{print $1}')"
        printf '%s:%s:%s\n' "$revision" "$dirty" "$untracked"
    else
        find "$source_root" -type f -print0 | xargs -0 shasum -a 256 | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
    fi
}

ensure_homebrew_path() {
    if command -v brew >/dev/null 2>&1; then
        return
    fi

    local candidate brew_dir
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$candidate" ]]; then
            brew_dir="$(dirname "$candidate")"
            case ":$PATH:" in
                *":$brew_dir:"*) ;;
                *) export PATH="$brew_dir:$PATH" ;;
            esac
            return
        fi
    done
}

install_host_dependencies() {
    ensure_homebrew_path
    if [[ "$SKIP_INSTALL" == true ]]; then
        return
    fi
    require_command brew
    for package in cmake ninja swig pkg-config; do
        if ! brew list --formula "$package" >/dev/null 2>&1; then
            run_logged "brew install $package" brew install "$package"
        fi
    done
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

prepare_overlay() {
    local overlay="$JOB_ROOT/osre"
    mkdir -p "$overlay"
    cp -a "$REPO_ROOT/lib/assimp_view/contrib/osre/." "$overlay/"

    # SDL 2.32.x needs a small Catalyst-only compatibility shim. Keep the
    # official Apple target macros intact, select SDL's UIKit sources, and
    # disable the unused Metal renderer (the viewer uses OpenGL).
    local port_overlay="$JOB_ROOT/vcpkg-ports"
    mkdir -p "$port_overlay"
    cp -a "$VCPKG_ROOT_EFFECTIVE/ports/sdl2" "$port_overlay/"

    cat > "$overlay/vcpkg.json" <<'EOF'
{
  "dependencies": [
    "glm",
    "sdl2"
  ]
}
EOF

    mkdir -p "$JOB_ROOT/apple-compat/include/GL"
    cat > "$JOB_ROOT/apple-compat/include/GL/glew.h" <<'EOF'
#pragma once

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST
#include <OpenGLES/ES3/gl.h>
#include <OpenGLES/ES2/glext.h>
#else
#include <OpenGL/gl3.h>
#include <OpenGL/glext.h>
#endif

#if TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST
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
    // Polygon mode is not part of OpenGL ES; filled rasterization is the
    // portable default for the iOS renderer.
}
#endif

#if TARGET_OS_MACCATALYST
/* macOS OpenGL headers omit legacy constants still referenced by OSRE. */
#ifndef GL_MAX_TEXTURE_UNITS
#define GL_MAX_TEXTURE_UNITS GL_MAX_TEXTURE_IMAGE_UNITS
#endif
#ifndef GL_MAX_TEXTURE_COORDS
#define GL_MAX_TEXTURE_COORDS GL_MAX_VERTEX_ATTRIBS
#endif
#ifndef GL_LIGHTING
#define GL_LIGHTING 0x0B50
#endif
#ifndef GL_CLAMP
#define GL_CLAMP GL_CLAMP_TO_EDGE
#endif
#endif

#ifndef GLEW_OK
#define GLEW_OK 0
#endif

static GLboolean glewExperimental = GL_TRUE;
static inline GLenum glewInit(void) { return GLEW_OK; }
EOF
    cat > "$JOB_ROOT/apple-compat/include/GL/gl.h" <<'EOF'
#pragma once

#include <GL/glew.h>
EOF

    cat > "$JOB_ROOT/maccatalyst-compat.h" <<'EOF'
#pragma once

#include <TargetConditionals.h>

/* SDL_platform.h rewrites Apple's target macros and treats Catalyst as iOS.
 * Keep Apple's official TargetConditionals intact and bypass only SDL's
 * internal platform header so SDL_opengl.h exposes the desktop API. */
#define SDL_platform_h_
#define __IPHONEOS__ 1
#undef __MACOSX__
#ifndef MAC_OS_X_VERSION_MIN_REQUIRED
#define MAC_OS_X_VERSION_MIN_REQUIRED 150000
#endif

#ifdef __cplusplus
extern "C" {
#endif
extern const char *SDL_GetPlatform(void);
#ifdef __cplusplus
}
#endif
EOF

    perl -0pi -e 's/#elif defined\(__APPLE__\) \|\| defined\(__MACH__\)\r?\n#\s*error "Currently not supported platform"/#elif defined(__APPLE__) || defined(__MACH__)\n#    define OSRE_APPLE/' \
        "$overlay/src/Engine/Common/osre_common.h"
    perl -0pi -e 's/find_package\(GLEW\s+REQUIRED\)/if(NOT APPLE)\n    find_package(GLEW REQUIRED)\n    set(OSRE_GLEW_LINK GLEW::GLEW)\nendif()/' \
        "$overlay/CMakeLists.txt"
    perl -0pi -e 's/\n    glEnable\(GL_MULTISAMPLE\);/\n#if !defined(__ANDROID__) \&\& !defined(__APPLE__)\n    glEnable(GL_MULTISAMPLE);\n#endif/' \
        "$overlay/src/Engine/RenderBackend/OGLRenderer/OGLRenderBackend.cpp"
    perl -0pi -e 's/#if defined\(MACOS\) \|\| defined\(TARGET_OS_MAC\)/#if defined(MACOS) || (defined(TARGET_OS_MAC) \&\& !defined(__APPLE__))/' \
        "$overlay/contrib/assimp/contrib/zlib/zutil.h"
    perl -0pi -e 's/#include <malloc\.h>/#if defined(__APPLE__)\n#include <stdlib.h>\n#else\n#include <malloc.h>\n#endif/' \
        "$overlay/contrib/cppcore/include/cppcore/CPPCoreCommon.h"
    sed -i '' 's/rhs\.m_QueueData/rhs.mQueueData/g' \
        "$overlay/contrib/cppcore/include/cppcore/Container/TQueue.h"
    perl -0pi -e 's/ADD_LIBRARY\(\s*osre\s+SHARED/ADD_LIBRARY( osre STATIC/' \
        "$overlay/src/Engine/CMakeLists.txt"
    perl -0pi -e 's/ADD_LIBRARY\(\s*cppcore\s+SHARED/ADD_LIBRARY( cppcore STATIC/' \
        "$overlay/contrib/cppcore/CMakeLists.txt"
    sed -i '' 's/cppcore)/$<TARGET_NAME_IF_EXISTS:cppcore>)/g' "$overlay/src/Engine/CMakeLists.txt"
    sed -i '' 's/target_link_libraries ( osre cppcore zlibstatic GLEW::GLEW ${platform_libs} assimp )/target_link_libraries ( osre $<TARGET_NAME_IF_EXISTS:cppcore> $<TARGET_NAME_IF_EXISTS:zlibstatic> ${OSRE_GLEW_LINK} ${platform_libs} $<TARGET_NAME_IF_EXISTS:assimp> )/' "$overlay/src/Engine/CMakeLists.txt"
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
        const char name[] = "AssimpView";
        for (unsigned int i = 0; name[i] != '\0'; ++i) {
            arg0[i] = name[i];
        }
    }
};

AssimpView::AssimpView() : m_impl(new Impl) {}
AssimpView::~AssimpView() { Shutdown(); delete m_impl; m_impl = nullptr; }

bool AssimpView::Initialize(int width, int height) {
    if (m_impl == nullptr || m_impl->initialized) return m_impl != nullptr;
    m_impl->initialized = m_impl->app.initWindow(
        0, 0, static_cast<OSRE::ui32>(width), static_cast<OSRE::ui32>(height),
        "Assimp View", OSRE::App::WindowMode::Windowed,
        OSRE::App::WindowType::Root,
        OSRE::App::RenderBackendType::OpenGLRenderBackend);
    return m_impl->initialized;
}

bool AssimpView::LoadAsset(const char *path) {
    if (m_impl == nullptr || !m_impl->initialized || path == nullptr) return false;
    OSRE::IO::Uri uri{OSRE::String(path)};
    if (!uri.isValid()) return false;
    m_impl->app.importAsset(uri);
    return m_impl->app.hasModel();
}

bool AssimpView::Frame() {
    if (m_impl == nullptr || !m_impl->initialized || !m_impl->app.handleEvents()) return false;
    m_impl->app.update();
    m_impl->app.requestNextFrame();
    return true;
}

void AssimpView::Resize(int width, int height) {
    if (m_impl != nullptr && m_impl->initialized) m_impl->app.resize(0, 0, width, height);
}

void AssimpView::Shutdown() {
    if (m_impl != nullptr && m_impl->initialized) {
        m_impl->app.destroy();
        m_impl->initialized = false;
    }
}

bool AssimpView::HasModel() const { return m_impl != nullptr && m_impl->app.hasModel(); }

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
        -dllimport __Internal \
        -I"$JOB_ROOT" \
        -outdir "$JOB_ROOT/swig/csharp" \
        -o "$JOB_ROOT/swig/cxx/assimpviewmaui.cxx" \
        "$JOB_ROOT/assimpview.i"
    compgen -G "$JOB_ROOT/swig/csharp/*.cs" >/dev/null || die 'SWIG did not generate C# classes'
}

write_triplet() {
    local triplet="$1"
    local rid="$2"
    local triplet_file="$JOB_ROOT/triplets/$triplet.cmake"
    mkdir -p "$JOB_ROOT/triplets"
    if [[ "$rid" == maccatalyst-arm64 ]]; then
        cat > "$triplet_file" <<EOF
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_CMAKE_CONFIGURE_OPTIONS
    "-DCMAKE_OSX_SYSROOT=macosx"
    "-DCMAKE_OSX_ARCHITECTURES=arm64"
    "-DSDL_OPENGL=ON"
    "-DSDL_OPENGLES=OFF"
    "-DIOS=ON"
    "-DSDL_METAL=OFF"
    "-DSDL_RENDER_METAL=OFF"
    "-DSDL_HIDAPI=OFF"
    "-DSDL_JOYSTICK=OFF"
    "-DSDL_HAPTIC=OFF"
    "-DSDL_FILESYSTEM=OFF"
    "-DSDL_FILE=OFF"
    "-DSDL_LOCALE=OFF"
    "-DSDL_MISC=OFF"
    "-DSDL_AUDIO=OFF"
    "-DCMAKE_C_FLAGS=-F$(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport/System/Library/Frameworks -iframework $(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport/System/Library/Frameworks -include ${JOB_ROOT}/maccatalyst-compat.h -target arm64-apple-ios15.0-macabi"
    "-DCMAKE_CXX_FLAGS=-F$(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport/System/Library/Frameworks -iframework $(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport/System/Library/Frameworks -include ${JOB_ROOT}/maccatalyst-compat.h -target arm64-apple-ios15.0-macabi")
EOF
    elif [[ "$rid" == iossimulator-arm64 ]]; then
        cat > "$triplet_file" <<'EOF'
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_CMAKE_SYSTEM_VERSION 15.0)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_CMAKE_CONFIGURE_OPTIONS
    "-DCMAKE_OSX_SYSROOT=iphonesimulator"
    "-DCMAKE_OSX_ARCHITECTURES=arm64")
EOF
    else
        cat > "$triplet_file" <<'EOF'
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_CMAKE_SYSTEM_VERSION 15.0)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_CMAKE_CONFIGURE_OPTIONS
    "-DCMAKE_OSX_SYSROOT=iphoneos"
    "-DCMAKE_OSX_ARCHITECTURES=arm64")
EOF
    fi
}

write_cmake_project() {
    local overlay="$1"
    local native_out="$2"
    local rid="$3"
    local system_name="$4"
    local sysroot="$5"
    local architecture="$6"
    local cflags="$7"
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
include_directories(BEFORE "${JOB_ROOT}/apple-compat/include")
set(OSRE_BUILD_PLAYER OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_SAMPLES OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_ED OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_DOC OFF CACHE BOOL "" FORCE)
set(ASSIMP_BUILD_ASSIMP_TOOLS OFF CACHE BOOL "" FORCE)
set(ASSIMP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(ASSIMP_BUILD_ZLIB ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
add_subdirectory("${overlay}" "\${CMAKE_BINARY_DIR}/osre" EXCLUDE_FROM_ALL)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    target_link_libraries(osre "-framework OpenGLES")
else()
    target_link_libraries(osre "-framework OpenGL")
endif()
add_library(assimpviewmaui STATIC
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

merge_apple_static_libraries() {
    local rid="$1"
    local native_out="$2"
    local publish_root="$JOB_ROOT/publish/$rid/native"
    local merged="$publish_root/libassimpviewmaui.a"
    local native
    local filename
    local -a static_libraries=()

    mkdir -p "$publish_root"
    while IFS= read -r -d '' native; do
        filename="$(basename "$native")"
        # Assimp.Maui owns Assimp's public static library and publishes it
        # separately. Keep it external to avoid duplicate Assimp symbols.
        [[ "$filename" == libassimp.a ]] && continue
        static_libraries+=("$native")
    done < <(find "$native_out" -type f -name '*.a' -print0 | sort -z)

    ((${#static_libraries[@]} > 0)) || die "no Apple static libraries were generated for $rid"
    run_logged "libtool merge $rid" libtool -static -o "$merged" "${static_libraries[@]}"
    [[ -s "$merged" ]] || die "libtool did not generate $merged"
}

publish() {
    local rid="$1"
    local platform
    case "$rid" in
        ios-arm64|iossimulator-arm64) platform=iOS ;;
        maccatalyst-arm64) platform=MacCatalyst ;;
        *) die "no Apple platform mapping for $rid" ;;
    esac
    local platform_root="$OUTPUT_ROOT/src/Assimp.View.Maui/Platforms/$platform"
    local native_root="$platform_root/runtimes/$rid/native"
    mkdir -p "$platform_root/AssimpView" "$native_root"
    local lock_path="$platform_root/.assimp-view-publish.lock"
    until mkdir "$lock_path" 2>/dev/null; do sleep 0.2; done
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
install_host_dependencies
progress_update 'host dependencies'
require_command cmake
require_command swig
validate_swig
require_command xcrun
require_command clang++
require_command libtool
progress_update 'Apple toolchain'

prepare_dependency_cache
VCPKG_ROOT_EFFECTIVE="$(prepare_vcpkg)"
progress_update 'vcpkg toolchain'
OVERLAY_ROOT="$(prepare_overlay)"
write_bridge_sources
generate_bindings
progress_update 'SWIG C# bindings'

for rid in "${ABIS[@]}"; do
    case "$rid" in
        ios-arm64)
            platform=iOS
            sysroot=iphoneos
            system_name=iOS
            architecture=arm64
            cflags=''
            triplet=assimpview-arm64-ios
            ;;
        iossimulator-arm64)
            platform=iOS
            sysroot=iphonesimulator
            system_name=iOS
            architecture=arm64
            cflags=''
            triplet=assimpview-arm64-ios-simulator
            ;;
        maccatalyst-arm64)
            platform=MacCatalyst
            sysroot=macosx
            system_name=Darwin
            architecture=arm64
            cflags='-target arm64-apple-ios15.0-macabi'
            triplet=assimpview-arm64-maccatalyst
            ;;
        *) die "unsupported Apple RID '$rid'" ;;
    esac

    write_triplet "$triplet" "$rid"
    install_root="$JOB_ROOT/vcpkg-installed/$rid"
    native_out="$JOB_ROOT/native/$rid"
    build_dir="$JOB_ROOT/build/$rid"
    mkdir -p "$native_out" "$build_dir"

    if [[ "$SKIP_INSTALL" == false ]]; then
        run_logged "vcpkg install $rid" "$VCPKG_ROOT_EFFECTIVE/vcpkg" install \
            "--triplet=$triplet" \
            "--overlay-triplets=$JOB_ROOT/triplets" \
            "--overlay-ports=$JOB_ROOT/vcpkg-ports" \
            "--x-buildtrees-root=$JOB_ROOT/vcpkg-buildtrees" \
            "--x-manifest-root=$OVERLAY_ROOT" \
            "--x-install-root=$install_root" \
            --clean-after-build
    else
        install_root="$VCPKG_ROOT_EFFECTIVE/installed"
        [[ -d "$install_root" ]] || die "--skip-install requires a populated vcpkg installed directory: $install_root"
    fi
    progress_update "vcpkg $rid"

    write_cmake_project "$OVERLAY_ROOT" "$native_out" "$rid" "$system_name" "$sysroot" "$architecture" "$cflags"
    cmake_args=(
        -S "$JOB_ROOT/project"
        -B "$build_dir"
        -G Ninja
        "-DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT_EFFECTIVE/scripts/buildsystems/vcpkg.cmake"
        "-DVCPKG_TARGET_TRIPLET=$triplet"
        "-DVCPKG_OVERLAY_TRIPLETS=$JOB_ROOT/triplets"
        "-DVCPKG_OVERLAY_PORTS=$JOB_ROOT/vcpkg-ports"
        "-DVCPKG_INSTALLED_DIR=$install_root"
        "-DCMAKE_SYSTEM_NAME=$system_name"
        "-DCMAKE_OSX_SYSROOT=$sysroot"
        "-DCMAKE_OSX_ARCHITECTURES=$architecture"
        -DCMAKE_BUILD_TYPE=Release
        -DUSE_PLATFORM=VK_USE_PLATFORM_METAL_EXT
    )
    if [[ -n "$cflags" ]]; then
        cmake_args+=("-DCMAKE_C_FLAGS=$cflags" "-DCMAKE_CXX_FLAGS=$cflags")
    fi
    run_logged "CMake configure $rid" cmake "${cmake_args[@]}"
    progress_update "CMake configure $rid"
    run_logged "CMake build $rid" cmake --build "$build_dir" --config Release --parallel "$JOBS"
    progress_update "CMake build $rid"

    merge_apple_static_libraries "$rid" "$native_out"
    publish "$rid"
    progress_update "publish $rid"
    progress_log "built Apple $rid ($platform)"
done

