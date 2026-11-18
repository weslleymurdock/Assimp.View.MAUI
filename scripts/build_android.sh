#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

die() {
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
  --output-root <path>     Repository/output root; defaults to this repository
  --vcpkg-root <path>      Existing vcpkg checkout
  --ndk-version <version>  Android NDK version (default: 26.1.10909125)
  --api <number>           Minimum Android API (default: 24)
  --jobs <number>          Parallel build jobs
  --log-level <level>      off, error, warn, info, debug or trace (default: off)
  --progress <mode>        auto, always or never (default: auto)
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
    printf 'using SWIG %s with C# Doxygen support\n' "$version"
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
        android-arm) printf '%s\n' arm-android ;;
        android-arm64) printf '%s\n' arm64-android ;;
        android-x86) printf '%s\n' x86-android ;;
        android-x86_64) printf '%s\n' x64-android ;;
        *) die "unsupported Android RID '$1'" ;;
    esac
}

ABIS=()
OUTPUT_ROOT="$REPO_ROOT"
REQUESTED_VCPKG_ROOT="${VCPKG_ROOT:-}"
NDK_VERSION="${ANDROID_NDK_VERSION:-26.1.10909125}"
ANDROID_API="${ANDROID_MIN_SDK_VERSION:-24}"
JOBS="${CMAKE_BUILD_PARALLEL_LEVEL:-}"
SKIP_INSTALL=false
LOG_LEVEL=off
PROGRESS_MODE=auto

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
declare -A SEEN_ABIS=()
UNIQUE_ABIS=()
for rid in "${ABIS[@]}"; do
    if [[ -z "${SEEN_ABIS[$rid]+present}" ]]; then
        SEEN_ABIS[$rid]=1
        UNIQUE_ABIS+=("$rid")
    fi
done
ABIS=("${UNIQUE_ABIS[@]}")

if [[ -z "$JOBS" ]]; then
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
[[ "$ANDROID_API" =~ ^[0-9]+$ ]] || die "--api must be an integer"

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
            printf '[debug] %s:' "$label" >&2
            printf ' %q' "$@" >&2
            printf '\n' >&2
        fi
        "$@" >&2 2>&1
        return $?
    fi

    if "$@" >>"$COMMAND_LOG" 2>&1; then
        return 0
    else
        status=$?
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

progress_update() {
    PROGRESS_COMPLETED=$((PROGRESS_COMPLETED + 1))
    progress_draw "$1" "$PROGRESS_COMPLETED" "$PROGRESS_TOTAL"
}

progress_finish() {
    if [[ "$PROGRESS_ENABLED" == true ]]; then
        printf '\n' >&2
        PROGRESS_ENABLED=false
    fi
}

install_host_dependencies() {
    if [[ "$SKIP_INSTALL" == true ]]; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        local packages=(ca-certificates cmake ninja-build swig git curl unzip tar build-essential)
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

    if [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]]; then
        export ANDROID_NDK_HOME
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
    export ANDROID_NDK_HOME="$ndk_path"
}

prepare_vcpkg() {
    if [[ -n "$REQUESTED_VCPKG_ROOT" && -f "$REQUESTED_VCPKG_ROOT/vcpkg" ]]; then
        printf '%s\n' "$REQUESTED_VCPKG_ROOT"
        return
    fi

    local source_root="$REQUESTED_VCPKG_ROOT"
    if [[ -z "$source_root" ]]; then
        source_root="$REPO_ROOT/lib/assimp_view/contrib/osre/contrib/vcpkg"
    fi
    [[ -d "$source_root" ]] || die "vcpkg source not found: $source_root"

    local local_root="$JOB_ROOT/vcpkg"
    mkdir -p "$local_root"
    cp -a "$source_root/." "$local_root/"
    if [[ ! -f "$local_root/vcpkg" ]]; then
        [[ -x "$local_root/bootstrap-vcpkg.sh" ]] || die "bootstrap-vcpkg.sh not found in $source_root"
        if ! (cd "$local_root" && run_logged 'vcpkg bootstrap' ./bootstrap-vcpkg.sh -disableMetrics); then
            die 'vcpkg bootstrap failed'
        fi
    fi
    [[ -f "$local_root/vcpkg" ]] || die "vcpkg bootstrap failed"
    printf '%s\n' "$local_root"
}

create_overlay() {
    local overlay="$JOB_ROOT/osre"
    mkdir -p "$overlay"
    cp -a "$REPO_ROOT/lib/assimp_view/contrib/osre/." "$overlay/"
    sed -i 's/cppcore)/$<TARGET_NAME_IF_EXISTS:cppcore>)/g' "$overlay/src/Engine/CMakeLists.txt"
    sed -i 's/target_link_libraries ( osre cppcore zlibstatic GLEW::GLEW ${platform_libs} assimp )/target_link_libraries ( osre $<TARGET_NAME_IF_EXISTS:cppcore> $<TARGET_NAME_IF_EXISTS:zlibstatic> GLEW::GLEW ${platform_libs} $<TARGET_NAME_IF_EXISTS:assimp> )/' "$overlay/src/Engine/CMakeLists.txt"
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
#define protected public
#include "ModelLoadingApp.h"
#undef protected

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
        OSRE::RenderBackend::RenderBackendType::OpenGLRenderBackend);
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
    "${REPO_ROOT}/lib/assimp_view/src/ModelLoading.cpp"
    "${JOB_ROOT}/AssimpViewBridge.cpp"
    "${JOB_ROOT}/swig/cxx/assimpviewmaui.cxx")
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
    local temporary="${destination}.tmp.${BASHPID}.${RANDOM}"
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
install_host_dependencies
progress_update 'host dependencies'
require_command cmake
require_command swig
validate_swig

if [[ "$SKIP_INSTALL" == false ]]; then
    ensure_android_toolchain
else
    : "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME is required with --skip-install}"
fi
progress_update 'Android SDK and NDK'

VCPKG_ROOT_EFFECTIVE="$(prepare_vcpkg)"
progress_update 'vcpkg toolchain'
OVERLAY_ROOT="$(create_overlay)"
write_bridge_sources
generate_bindings
progress_update 'SWIG C# bindings'

for rid in "${ABIS[@]}"; do
    abi="$(android_abi "$rid")"
    triplet="$(vcpkg_triplet "$rid")"
    install_root="$JOB_ROOT/vcpkg-installed/$rid"
    native_out="$JOB_ROOT/native/$rid"
    build_dir="$JOB_ROOT/build/$rid"
    mkdir -p "$native_out" "$build_dir"

    if [[ "$SKIP_INSTALL" == false ]]; then
        run_logged "vcpkg install $rid" "$VCPKG_ROOT_EFFECTIVE/vcpkg" install \
            "--triplet=$triplet" \
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
        "-DVCPKG_INSTALLED_DIR=$install_root" \
        "-DANDROID_ABI=$abi" \
        "-DANDROID_PLATFORM=android-$ANDROID_API" \
        "-DANDROID_STL=c++_shared" \
        "-DCMAKE_BUILD_TYPE=Release" \
        "-DANDROID_NDK=$ANDROID_NDK_HOME" \
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
    printf 'built Android %s (%s)\n' "$rid" "$abi"
done

