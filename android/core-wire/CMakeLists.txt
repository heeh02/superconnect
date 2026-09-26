cmake_minimum_required(VERSION 3.22.1)
project(superconnect_foss_android_wire LANGUAGES C CXX)

if(NOT DEFINED SC_REPO_ROOT)
    get_filename_component(SC_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
endif()

# Integration selected the canonical full Android ABI for the common Mac/Android local proof.
set(SC_CORE_FFI_VARIANT "full")
set(SC_CORE_FFI_OUTPUT_ROOT "${CMAKE_CURRENT_BINARY_DIR}/core-ffi-output")
set(SC_CORE_CARGO_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/core-ffi-cargo-target")
set(SC_CORE_ARCHIVE
    "${SC_CORE_FFI_OUTPUT_ROOT}/aarch64-linux-android/ffi-release/libsuperconnect_core.a")

file(GLOB_RECURSE SC_CORE_INPUTS CONFIGURE_DEPENDS
    "${SC_REPO_ROOT}/core/src/*.rs"
    "${SC_REPO_ROOT}/core/tests/*.rs"
    "${SC_REPO_ROOT}/core/include/*.h"
    "${SC_REPO_ROOT}/core/abi/*.json")
list(APPEND SC_CORE_INPUTS
    "${SC_REPO_ROOT}/.gitattributes"
    "${SC_REPO_ROOT}/core/Cargo.toml"
    "${SC_REPO_ROOT}/core/Cargo.lock"
    "${SC_REPO_ROOT}/core/build.rs"
    "${SC_REPO_ROOT}/qa/baselines/product-symbols/core-abi.txt"
    "${SC_REPO_ROOT}/release/TOOLCHAINS.lock.json"
    "${SC_REPO_ROOT}/rust-toolchain.toml"
    "${SC_REPO_ROOT}/tools/build-core-ffi.sh"
    "${SC_REPO_ROOT}/tools/core_abi_extract.py"
    "${SC_REPO_ROOT}/tools/core_abi_manifest.py"
    "${SC_REPO_ROOT}/tools/core_abi_model.py"
    "${SC_REPO_ROOT}/tools/core_abi_normalize.py"
    "${SC_REPO_ROOT}/tools/core_ffi_archive_validator.py"
    "${SC_REPO_ROOT}/tools/core_ffi_build_inputs.py"
    "${SC_REPO_ROOT}/tools/core_ffi_manifest_validator.py"
    "${SC_REPO_ROOT}/tools/core_ffi_receipt.py"
    "${SC_REPO_ROOT}/tools/core_ffi_receipt_common.py"
    "${SC_REPO_ROOT}/tools/lib/rust-toolchain.sh")

add_custom_command(
    OUTPUT "${SC_CORE_ARCHIVE}"
    COMMAND "${CMAKE_COMMAND}" -E env
        "SC_CORE_FFI_OUTPUT_ROOT=${SC_CORE_FFI_OUTPUT_ROOT}"
        "SC_CORE_CARGO_TARGET_DIR=${SC_CORE_CARGO_TARGET_DIR}"
        bash "${SC_REPO_ROOT}/tools/build-core-ffi.sh"
            --target aarch64-linux-android
            --profile ffi-release
            --variant "${SC_CORE_FFI_VARIANT}"
    DEPENDS ${SC_CORE_INPUTS}
    WORKING_DIRECTORY "${SC_REPO_ROOT}"
    COMMENT "Building canonical full Android arm64 Rust Core archive"
    VERBATIM)
add_custom_target(superconnect_foss_android_core DEPENDS "${SC_CORE_ARCHIVE}")

add_library(superconnect_core STATIC IMPORTED GLOBAL)
set_target_properties(superconnect_core PROPERTIES IMPORTED_LOCATION "${SC_CORE_ARCHIVE}")

set(SC_FOSS_RECEIVER_SOURCES
    src/AndroidPointerJni.cpp
    src/AndroidAdmissionBridge.cpp
    src/AndroidAdmissionJni.cpp
    src/AndroidAuthBridge.cpp
    src/AndroidAuthJni.cpp
    src/AndroidCapabilityBridge.cpp
    src/AndroidCapabilityJni.cpp
    src/AndroidCapabilityIntentV2Bridge.cpp
    src/AndroidCapabilityIntentV2Jni.cpp
    src/AndroidCoreAbiObserver.cpp
    src/AndroidReceiverProgressJni.cpp
    src/AndroidSessionBridge.cpp
    src/AndroidSessionControlJni.cpp
    src/AndroidSessionJni.cpp
    src/AndroidWireBridge.cpp
    src/AndroidWireJni.cpp)

add_library(superconnect_wire SHARED ${SC_FOSS_RECEIVER_SOURCES})
add_dependencies(superconnect_wire superconnect_foss_android_core)
target_compile_features(superconnect_wire PRIVATE cxx_std_17)
target_compile_options(superconnect_wire PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
target_include_directories(superconnect_wire PRIVATE
    include
    "${SC_REPO_ROOT}/core/include")
target_link_options(superconnect_wire PRIVATE
    "LINKER:--no-undefined"
    "LINKER:--undefined=sc_android_core_abi_observe_fd_v1"
    "LINKER:--undefined=sc_core_abi_version_v1"
    "LINKER:--undefined=sc_core_abi_identity_v1"
    "LINKER:--undefined=sc_secure_connection_new_v1"
    "LINKER:--undefined=sc_secure_connection_push_v1")
target_link_libraries(superconnect_wire PRIVATE superconnect_core)
