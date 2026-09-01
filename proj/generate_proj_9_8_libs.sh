#!/usr/bin/env bash

#
# Build the static PROJ library and its SQLite dependency for esmini.
#
# The generated staging directory contains headers and static libraries. PROJ
# resources, including proj.db, are embedded in the PROJ library.
#
# Prerequisites:
# - Git with Bash
# - CMake
# - A C/C++ compiler (Visual Studio, gcc, or Xcode)
#
# Usage:
# - Run this script from the repository root using Git Bash.
#

set -euo pipefail

PROJ_REPOSITORY="https://github.com/OSGeo/PROJ.git"
PROJ_VERSION="9.8.1"
SQLITE_VERSION="3530400"
PARALLEL_BUILDS="-j4"

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    GENERATOR_ARGUMENTS=(-G "Visual Studio 17 2022" -T v142 -A x64)
    TARGET_DIR="v10"
    LIB_EXTENSION="lib"
    LIB_PREFIX=""
elif [[ "$OSTYPE" == linux-gnu* ]]; then
    GENERATOR_ARGUMENTS=(-G "Unix Makefiles")
    TARGET_DIR="linux"
    LIB_EXTENSION="a"
    LIB_PREFIX="lib"
elif [[ "$OSTYPE" == darwin* ]]; then
    GENERATOR_ARGUMENTS=(-G "Unix Makefiles")
    TARGET_DIR="mac"
    LIB_EXTENSION="a"
    LIB_PREFIX="lib"
    MACOS_ARCHITECTURES="arm64;x86_64"
else
    echo "Unsupported platform: $OSTYPE. Supported platforms are Windows, Linux, and macOS." >&2
    exit 1
fi

if ! command -v cmake >/dev/null; then
    echo "CMake was not found in PATH." >&2
    exit 1
fi

if ! command -v git >/dev/null; then
    echo "Git was not found in PATH." >&2
    exit 1
fi

ROOT_DIR="$(pwd)"
INSTALL_DIR="$ROOT_DIR/install"

configure_and_install() {
    local source_dir="$1"
    local build_dir="$2"
    local build_config="$3"
    shift 3

    cmake -S "$source_dir" -B "$build_dir" "${GENERATOR_ARGUMENTS[@]}" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        "$@"
    cmake --build "$build_dir" $PARALLEL_BUILDS --config "$build_config" --target install
}

build_sqlite() {
    local sqlite_dir="$ROOT_DIR/sqlite-amalgamation-$SQLITE_VERSION"
    local sqlite_zip="sqlite-amalgamation-$SQLITE_VERSION.zip"

    if [[ ! -d "$sqlite_dir" ]]; then
        curl --fail --location "https://www.sqlite.org/2024/$sqlite_zip" --output "$sqlite_zip"
        unzip -q "$sqlite_zip"
    fi

    cat > "$sqlite_dir/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.10)
project(sqlite3 LANGUAGES C)
find_package(Threads REQUIRED)
add_library(sqlite3_static STATIC sqlite3.c)
target_include_directories(sqlite3_static PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}> $<INSTALL_INTERFACE:include>)
set_target_properties(sqlite3_static PROPERTIES OUTPUT_NAME sqlite3 DEBUG_POSTFIX d)
add_executable(sqlite3 shell.c)
target_link_libraries(sqlite3 PRIVATE sqlite3_static Threads::Threads ${CMAKE_DL_LIBS})
install(TARGETS sqlite3_static ARCHIVE DESTINATION lib)
install(TARGETS sqlite3 RUNTIME DESTINATION bin)
install(FILES sqlite3.h sqlite3ext.h DESTINATION include)
EOF

    local common_args=(-DCMAKE_POSITION_INDEPENDENT_CODE=ON)
    if [[ "$OSTYPE" == darwin* ]]; then
        common_args+=(-DCMAKE_OSX_ARCHITECTURES="$MACOS_ARCHITECTURES")
    fi

    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        configure_and_install "$sqlite_dir" "$ROOT_DIR/build-sqlite" Debug "${common_args[@]}"
        configure_and_install "$sqlite_dir" "$ROOT_DIR/build-sqlite" Release "${common_args[@]}"
    else
        configure_and_install "$sqlite_dir" "$ROOT_DIR/build-sqlite-debug" Debug -DCMAKE_BUILD_TYPE=Debug "${common_args[@]}"
        configure_and_install "$sqlite_dir" "$ROOT_DIR/build-sqlite-release" Release -DCMAKE_BUILD_TYPE=Release "${common_args[@]}"
    fi
}

build_proj() {
    local proj_dir="$ROOT_DIR/proj-source"
    local sqlite_release="$INSTALL_DIR/lib/${LIB_PREFIX}sqlite3.${LIB_EXTENSION}"
    local sqlite_debug="$INSTALL_DIR/lib/${LIB_PREFIX}sqlite3d.${LIB_EXTENSION}"
    local sqlite_executable="$INSTALL_DIR/bin/sqlite3"
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        sqlite_executable+=".exe"
    fi
    local common_args=(
        -DBUILD_SHARED_LIBS=OFF
        -DBUILD_TESTING=OFF
        -DBUILD_APPS=OFF
        -DENABLE_CURL=OFF
        -DENABLE_TIFF=OFF
        -DEMBED_RESOURCE_FILES=ON
        -DUSE_ONLY_EMBEDDED_RESOURCE_FILES=ON
        -DEXE_SQLITE3="$sqlite_executable"
        -DSQLite3_INCLUDE_DIR="$INSTALL_DIR/include"
        -DSQLite3_LIBRARY="$sqlite_release"
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DCMAKE_DEBUG_POSTFIX=d
    )

    if [[ ! -d "$proj_dir/.git" ]]; then
        git clone --depth 1 --branch "$PROJ_VERSION" "$PROJ_REPOSITORY" "$proj_dir"
    fi

    if [[ "$OSTYPE" == darwin* ]]; then
        common_args+=(-DCMAKE_OSX_ARCHITECTURES="$MACOS_ARCHITECTURES")
    fi

    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        configure_and_install "$proj_dir" "$ROOT_DIR/build-proj" Debug "${common_args[@]}"
        configure_and_install "$proj_dir" "$ROOT_DIR/build-proj" Release "${common_args[@]}"
    else
        configure_and_install "$proj_dir" "$ROOT_DIR/build-proj-debug" Debug -DCMAKE_BUILD_TYPE=Debug "${common_args[@]}"
        configure_and_install "$proj_dir" "$ROOT_DIR/build-proj-release" Release -DCMAKE_BUILD_TYPE=Release "${common_args[@]}"
    fi
}

package_proj() {
    local release_library="$INSTALL_DIR/lib/${LIB_PREFIX}proj.${LIB_EXTENSION}"
    local debug_library="$INSTALL_DIR/lib/${LIB_PREFIX}projd.${LIB_EXTENSION}"
    local development_dir="$ROOT_DIR/$TARGET_DIR"

    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        debug_library="$INSTALL_DIR/lib/proj_d.lib"
    fi

    rm -rf "$development_dir"
    mkdir -p "$development_dir/include" "$development_dir/lib"
    cp -R "$INSTALL_DIR/include/." "$development_dir/include/"
    cp "$release_library" "$development_dir/lib/"
    cp "$debug_library" "$development_dir/lib/${LIB_PREFIX}projd.${LIB_EXTENSION}"
    cp "$INSTALL_DIR/lib/${LIB_PREFIX}sqlite3.${LIB_EXTENSION}" "$development_dir/lib/"
    cp "$INSTALL_DIR/lib/${LIB_PREFIX}sqlite3d.${LIB_EXTENSION}" "$development_dir/lib/"
}

build_sqlite
build_proj
package_proj

echo "Created package staging directory '$TARGET_DIR' with embedded PROJ resources."