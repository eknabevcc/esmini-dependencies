#!/usr/bin/env bash

### Setup
set -euo pipefail

BUILD_JOBS=4
BUILD_TYPE=${BUILD_TYPE:-Release}
PROTOBUF_SHARED=${PROTOBUF_SHARED:-OFF}

if [[ "${BUILD_TYPE}" != "Release" && "${BUILD_TYPE}" != "Debug" ]]; then
    echo "Unsupported BUILD_TYPE: ${BUILD_TYPE}. Use Release or Debug."
    exit 1
fi

if [[ "${PROTOBUF_SHARED}" != "ON" && "${PROTOBUF_SHARED}" != "OFF" ]]; then
    echo "Unsupported PROTOBUF_SHARED: ${PROTOBUF_SHARED}. Use ON or OFF."
    exit 1
fi

ABSL_SHARED="OFF"
ABSL_WINDOWS_EXPORT_ALL_SYMBOLS_FLAG=""
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && [[ "${PROTOBUF_SHARED}" == "ON" ]]; then
    ABSL_WINDOWS_EXPORT_ALL_SYMBOLS_FLAG="-DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON"
    ABSL_SHARED="ON" # Windows needs to link shared abseil
fi

OSX_ARCH=""
LIB_EXE=""
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    # Parallel build argument
    BUILD_PARALLEL_ARGS=(--parallel "${BUILD_JOBS}")

    # Visual Studio 2022 using toolkit from Visual Studio 2017
    GENERATOR=("Visual Studio 17 2022")
    GENERATOR_TOOLSET="v142"
    GENERATOR_ARGUMENTS="-A x64 -T ${GENERATOR_TOOLSET}"

    # Find lib.exe for linking multiple .lib files
    if [[ -n "${LIB_EXE_PATH:-}" ]]; then
        LIB_EXE="${LIB_EXE_PATH}"
    else
        # Try to find lib.exe using vswhere
        VSWHERE_PATH=vswhere.exe
        if ! command -v ${VSWHERE_PATH} &> /dev/null; then
            # Assume default installation path for Visual Studio 2022 on Windows
            VSWHERE_PATH="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
        fi
        VS_INSTALL_PATH="$("${VSWHERE_PATH}" -latest -products "*" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)"
        if [[ -n "${VS_INSTALL_PATH}" ]]; then
            # Find the latest MSVC version and lib.exe using find
            LIB_EXE=$(find "${VS_INSTALL_PATH}/VC/Tools/MSVC" -name "lib.exe" -path "*/bin/Hostx64/x64/lib.exe" 2>/dev/null | sort -V | tail -n1)
        fi
        # Fallback: check if lib.exe is in PATH
        if [[ -z "${LIB_EXE}" ]] && command -v lib.exe &> /dev/null; then
            LIB_EXE="lib.exe"
        fi
    fi

    if [[ -z "${LIB_EXE}" ]]; then
        echo "Warning: lib.exe not found. Set LIB_EXE_PATH environment variable to specify its location."
    fi
elif [[ "$OSTYPE" == "linux-gnu"* || "$OSTYPE" == "darwin"* ]]; then
    # Parallel build argument
    BUILD_PARALLEL_ARGS=(-j "${BUILD_JOBS}")

    # Unix Makefiles (for Ubuntu and other Linux systems)
    GENERATOR=("Unix Makefiles")
    GENERATOR_ARGUMENTS=""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OSX_ARCH="-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64"
    fi
else
    echo Unknown OSTYPE: $OSTYPE
    exit 1
fi

ROOT_DIR=$(pwd)
DEPS_INSTALL_FOLDER="${ROOT_DIR}/osi-dependencies/install"
OSI_INSTALL_FOLDER="${ROOT_DIR}/osi-cpp-install"

rm -rf osi-dependencies
mkdir -p "${DEPS_INSTALL_FOLDER}"
cd osi-dependencies

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    DEPS_CMAKE_PREFIX=$(cygpath -m "${DEPS_INSTALL_FOLDER}")
else
    DEPS_CMAKE_PREFIX="${DEPS_INSTALL_FOLDER}"
fi

### Building

# build and install zlib
git clone --depth 1 --branch v1.3.1 https://github.com/madler/zlib.git
cd zlib
mkdir build
cmake -G "${GENERATOR[@]}" ${GENERATOR_ARGUMENTS} -S . -B build \
    -DCMAKE_INSTALL_PREFIX="${DEPS_CMAKE_PREFIX}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    ${OSX_ARCH:+"${OSX_ARCH}"}

cmake --build build --config "${BUILD_TYPE}" "${BUILD_PARALLEL_ARGS[@]}"
cmake --install build --config "${BUILD_TYPE}" --prefix "${DEPS_CMAKE_PREFIX}"

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    rm "${DEPS_CMAKE_PREFIX}/lib/libz.so"*
elif [[ "$OSTYPE" == "darwin"* ]]; then
    rm "${DEPS_CMAKE_PREFIX}/lib/libz"*.dylib
else # Windows
    if [[ "${BUILD_TYPE}" == "Release" ]]; then
        rm "${DEPS_CMAKE_PREFIX}/lib/zlib.lib"
    else # Debug
        rm "${DEPS_CMAKE_PREFIX}/lib/zlibd.lib"
    fi
fi
cd "${ROOT_DIR}/osi-dependencies"


# build and install abseil
git clone --depth 1 --branch 20240722.1 https://github.com/abseil/abseil-cpp.git
cd abseil-cpp
mkdir build
cmake -G "${GENERATOR[@]}" ${GENERATOR_ARGUMENTS} -S . -B build \
	-DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    ${ABSL_WINDOWS_EXPORT_ALL_SYMBOLS_FLAG:+"${ABSL_WINDOWS_EXPORT_ALL_SYMBOLS_FLAG}"} \
    -DBUILD_SHARED_LIBS="${ABSL_SHARED}" \
	-DABSL_ENABLE_INSTALL=ON \
	-DABSL_BUILD_TESTING=OFF \
	-DABSL_USE_GOOGLETEST_HEAD=OFF \
	-DABSL_MSVC_STATIC_RUNTIME=OFF \
	-DABSL_PROPAGATE_CXX_STD=ON \
    ${OSX_ARCH:+"${OSX_ARCH}"}

cmake --build build --config "${BUILD_TYPE}" "${BUILD_PARALLEL_ARGS[@]}"
cmake --install build --config "${BUILD_TYPE}" --prefix "${DEPS_CMAKE_PREFIX}"
cd "${ROOT_DIR}/osi-dependencies"

# build and install protobuf
git clone --depth 1 --branch v29.3 https://github.com/protocolbuffers/protobuf.git
cd protobuf

echo "Modifying third_party/utf8_range/CMakeLists.txt to always build static libs"
# Always build static utf8 libs instead of relying on protobuf_BUILD_SHARED_LIBS flag
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux & Windows (GNU sed syntax)
    sed -i 's/add_library.*utf8_validity.*utf8_validity.cc.*/add_library (utf8_validity STATIC utf8_validity.cc utf8_range.c)/' third_party/utf8_range/CMakeLists.txt
    sed -i 's/add_library[[:space:]]*(utf8_range.*/add_library (utf8_range STATIC/' third_party/utf8_range/CMakeLists.txt
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS (BSD sed syntax - requires the '')
    sed -i '' 's/add_library.*utf8_validity.*utf8_validity.cc.*/add_library (utf8_validity STATIC utf8_validity.cc utf8_range.c)/' third_party/utf8_range/CMakeLists.txt
    sed -i '' 's/add_library[[:space:]]*(utf8_range.*/add_library (utf8_range STATIC/' third_party/utf8_range/CMakeLists.txt
else
    echo "Unknown OS type: $OSTYPE"
    exit 1
fi

cmake -G "${GENERATOR[@]}" ${GENERATOR_ARGUMENTS} -S . -B cmake-out \
    -DCMAKE_INSTALL_PREFIX="${DEPS_CMAKE_PREFIX}" \
	-DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_MSVC_STATIC_RUNTIME=OFF \
	-Dprotobuf_ABSL_PROVIDER="package" \
    -DCMAKE_PREFIX_PATH="${DEPS_CMAKE_PREFIX}" \
    -Dprotobuf_BUILD_SHARED_LIBS="${PROTOBUF_SHARED}" \
    ${OSX_ARCH:+"${OSX_ARCH}"}

cmake --build cmake-out --config "${BUILD_TYPE}" --clean-first "${BUILD_PARALLEL_ARGS[@]}"
cmake --install cmake-out --config "${BUILD_TYPE}" --prefix "${DEPS_CMAKE_PREFIX}"
cd "$ROOT_DIR"

# build and install osi
git clone --branch v3.8.0-rc1 --recurse-submodules https://github.com/OpenSimulationInterface/osi-cpp.git
mkdir -p "$OSI_INSTALL_FOLDER"
cd osi-cpp
mkdir build

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    PROTO_CMAKE_DIR=$(cygpath -m "${DEPS_INSTALL_FOLDER}/lib/cmake/protobuf")
    OSI_INSTALL_PREFIX=$(cygpath -m "${OSI_INSTALL_FOLDER}")
    ABSL_INCLUDE_PATH=$(cygpath -m "${DEPS_INSTALL_FOLDER}/include")
    OSI_CXX_FLAGS_RELEASE="-EHsc -MD -DNDEBUG -O2 -I${ABSL_INCLUDE_PATH}"
    OSI_CXX_FLAGS_DEBUG="-EHsc -MDd -Od -Z7 -I${ABSL_INCLUDE_PATH}"
    if [[ "${PROTOBUF_SHARED}" == "ON" ]]; then
        OSI_CXX_FLAGS_RELEASE="${OSI_CXX_FLAGS_RELEASE} -DPROTOBUF_USE_DLLS -DABSL_CONSUME_DLL"
        OSI_CXX_FLAGS_DEBUG="${OSI_CXX_FLAGS_DEBUG} -DPROTOBUF_USE_DLLS -DABSL_CONSUME_DLL"
    fi
else
    PROTO_CMAKE_DIR="${DEPS_INSTALL_FOLDER}/lib/cmake/protobuf"
    OSI_INSTALL_PREFIX="${OSI_INSTALL_FOLDER}"
    ABSL_INCLUDE_PATH="${DEPS_INSTALL_FOLDER}/include"
    OSI_CXX_FLAGS_RELEASE="-I${ABSL_INCLUDE_PATH}"
    OSI_CXX_FLAGS_DEBUG="-I${ABSL_INCLUDE_PATH}"
fi

cmake -G "${GENERATOR[@]}" ${GENERATOR_ARGUMENTS} -S . -B build \
    "-DCMAKE_CXX_STANDARD=17" \
    "-DCMAKE_BUILD_TYPE=${BUILD_TYPE}" \
    "-DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON" \
    "-Dprotobuf_MODULE_COMPATIBLE=ON" \
    "-DProtobuf_DIR=${PROTO_CMAKE_DIR}" \
    "-DCMAKE_PREFIX_PATH=${DEPS_CMAKE_PREFIX}" \
    "-DCMAKE_CXX_FLAGS_RELEASE=${OSI_CXX_FLAGS_RELEASE}" \
    "-DCMAKE_CXX_FLAGS_DEBUG=${OSI_CXX_FLAGS_DEBUG}" \
    "-DCMAKE_INSTALL_PREFIX=${OSI_INSTALL_PREFIX}" \
    ${OSX_ARCH:+"${OSX_ARCH}"}

cmake --build build --config "${BUILD_TYPE}" --clean-first "${BUILD_PARALLEL_ARGS[@]}"
cmake --install build --config "${BUILD_TYPE}"

cd "$ROOT_DIR"

### Staging
if [[ "$PROTOBUF_SHARED" == "OFF" ]]; then
    LIB_DIR_NAME="lib"
else
    LIB_DIR_NAME="lib-dyn"
fi

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    STAGING_DIR="v10"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    STAGING_DIR="linux"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    STAGING_DIR="mac"
else
    echo "Unknown OSTYPE: $OSTYPE"
fi

BUILD_TYPE_LOWER=$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')
STAGING_DIR_LIB="${STAGING_DIR}/${LIB_DIR_NAME}/${BUILD_TYPE_LOWER}"
STAGING_DIR_INCLUDE="${STAGING_DIR}/include"

mkdir -p "$STAGING_DIR_LIB"
mkdir -p "$STAGING_DIR_INCLUDE"

## Copy include files
echo "- Copying dependency- and osi headers to ${STAGING_DIR_INCLUDE}"
cp -r "${DEPS_INSTALL_FOLDER}/include/"* "$STAGING_DIR_INCLUDE"
cp -r "${OSI_INSTALL_FOLDER}/include/osi3/"* "$STAGING_DIR_INCLUDE"

## Bundle all abseil static libs to one lib
echo "- Bundle abseil static libs to one lib"
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: Use native libtool (handles wildcards out-of-the-box)
    mac_libs=( "${DEPS_INSTALL_FOLDER}/lib/libabsl_"*.a )
    libtool -static -o "${DEPS_INSTALL_FOLDER}/lib/absl_combined.a" "${mac_libs[@]}"

elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
     echo "Pack all abseil static libs into one (absl_combined.a) using ar"
    (
      echo "CREATE ${DEPS_INSTALL_FOLDER}/lib/absl_combined.a"
      for lib in "${DEPS_INSTALL_FOLDER}/lib/libabsl_"*.a; do
        echo "ADDLIB $lib"
      done
      echo "SAVE"
      echo "END"
    ) | ar -M
else
     echo "Pack all abseil static libs into one (absl_combined.lib) using ${LIB_EXE}"
    "$LIB_EXE" "-OUT:${DEPS_INSTALL_FOLDER}"/lib/absl_combined.lib "${DEPS_INSTALL_FOLDER}"/lib/absl_*.lib
fi

## Remove useless protobuf-lite to prevent copying of it
rm "${DEPS_CMAKE_PREFIX}/lib/"*protobuf-lite*

## Copy libs
echo "- Copying all libs"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then

    # Dependency libs (abseil, upb, utf8 and libz), always .a
    cp "${DEPS_INSTALL_FOLDER}/lib/libz.a" "${STAGING_DIR_LIB}"
    if [[ "$PROTOBUF_SHARED" == "OFF" ]]; then
        cp "${DEPS_INSTALL_FOLDER}/lib/absl_combined.a" "${DEPS_INSTALL_FOLDER}/lib/libupb"*.a "${DEPS_INSTALL_FOLDER}/lib/libutf8"*.a "${STAGING_DIR_LIB}"
    fi

    if [[ "$PROTOBUF_SHARED" == "OFF" ]]; then
        # Static libs
        cp "${OSI_INSTALL_FOLDER}/lib/libopen_simulation_interface_pic.a" "$STAGING_DIR_LIB"
        cp "${DEPS_INSTALL_FOLDER}/lib/libprotobuf"*.a "$STAGING_DIR_LIB"
    else
        # Dynamic libs
        cp -P "${OSI_INSTALL_FOLDER}/lib/libopen_simulation_interface.so"* "$STAGING_DIR_LIB"
        cp -P "${DEPS_INSTALL_FOLDER}/lib/libprotobuf"*.so* "$STAGING_DIR_LIB"
    fi
elif [[ "$OSTYPE" == "darwin"* ]]; then

    # Dependency libs (abseil, upb, utf8 and libz), always .a
    cp "${DEPS_INSTALL_FOLDER}/lib/libz.a" "${STAGING_DIR_LIB}"
    if [[ "$PROTOBUF_SHARED" == "OFF" ]]; then
        cp "${DEPS_INSTALL_FOLDER}/lib/absl_combined.a" "${DEPS_INSTALL_FOLDER}/lib/libupb"*.a "${DEPS_INSTALL_FOLDER}/lib/libutf8"*.a "${STAGING_DIR_LIB}"
    fi

    if [[ "$PROTOBUF_SHARED" == "OFF" ]]; then
        # Static libs
        cp "${OSI_INSTALL_FOLDER}/lib/libopen_simulation_interface_pic.a" "$STAGING_DIR_LIB"
        cp "${DEPS_INSTALL_FOLDER}/lib/libprotobuf"*.a "$STAGING_DIR_LIB"
    else
        # Dynamic libs
        cp -P "${OSI_INSTALL_FOLDER}/lib/libopen_simulation_interface"*.dylib "$STAGING_DIR_LIB"
        cp -P "${DEPS_INSTALL_FOLDER}/lib/libprotobuf"*.dylib "$STAGING_DIR_LIB"
    fi

else # Windows
    # Dependency libs (abseil, upb, utf8 and libz), always .a
    cp "${DEPS_INSTALL_FOLDER}/lib/zlibstatic"*.lib "${STAGING_DIR_LIB}"
    if [[ "$PROTOBUF_SHARED" == "OFF" ]]; then
        cp "${DEPS_INSTALL_FOLDER}/lib/absl_combined.lib" "${DEPS_INSTALL_FOLDER}/lib/utf8"*.lib "${DEPS_INSTALL_FOLDER}/lib/libupb"*.lib "${STAGING_DIR_LIB}"
    fi

    if [[ "$PROTOBUF_SHARED" == "OFF" && "${BUILD_TYPE}" == "Release" ]]; then
        # Windows static release libs
        cp "${OSI_INSTALL_FOLDER}/lib/open_simulation_interface_pic.lib" "$STAGING_DIR_LIB"
        cp "${DEPS_INSTALL_FOLDER}/lib/libprotobuf.lib" "$STAGING_DIR_LIB"
    elif [[ "$PROTOBUF_SHARED" == "OFF" && "${BUILD_TYPE}" == "Debug" ]]; then
        # Windows static debug libs
        cp "${OSI_INSTALL_FOLDER}/lib/open_simulation_interface_pic.lib" "$STAGING_DIR_LIB"
        cp "${DEPS_INSTALL_FOLDER}/lib/libprotobufd.lib" "$STAGING_DIR_LIB"
    elif [[ "$PROTOBUF_SHARED" == "ON" && "${BUILD_TYPE}" == "Release" ]]; then
        # Windows dynamic release libs
        cp -P "${OSI_INSTALL_FOLDER}/lib/open_simulation_interface_pic.lib"* "$STAGING_DIR_LIB"
        cp -P "${OSI_INSTALL_FOLDER}/lib/open_simulation_interface.dll"* "$STAGING_DIR_LIB"
        cp -P "${DEPS_INSTALL_FOLDER}/lib/libprotobuf.lib" "$STAGING_DIR_LIB"
        cp -P "${DEPS_INSTALL_FOLDER}/bin/libprotobuf.dll" "$STAGING_DIR_LIB"
        cp -P "${DEPS_INSTALL_FOLDER}/lib/abseil_dll.lib" "$STAGING_DIR_LIB"
        cp -P "${DEPS_INSTALL_FOLDER}/bin/abseil_dll.dll" "$STAGING_DIR_LIB"
    elif [[ "$PROTOBUF_SHARED" == "ON" && "${BUILD_TYPE}" == "Debug" ]]; then
        # Windows dynamic release libs
        cp -P "${OSI_INSTALL_FOLDER}/lib/open_simulation_interface_pic.lib"* "$STAGING_DIR_LIB"
        cp -P "${OSI_INSTALL_FOLDER}/lib/open_simulation_interface.dll"* "$STAGING_DIR_LIB"
        cp -P "${DEPS_INSTALL_FOLDER}/lib/libprotobufd.lib" "$STAGING_DIR_LIB"
        cp -P "${DEPS_INSTALL_FOLDER}/bin/libprotobufd.dll" "$STAGING_DIR_LIB"
        cp -P "${DEPS_INSTALL_FOLDER}/lib/abseil_dll.lib" "$STAGING_DIR_LIB"
        cp -P "${DEPS_INSTALL_FOLDER}/bin/abseil_dll.dll" "$STAGING_DIR_LIB"
    else
        echo "Unknown combination of PROTOBUF_SHARED=$PROTOBUF_SHARED and BUILD_TYPE=${BUILD_TYPE}"
    fi
fi
