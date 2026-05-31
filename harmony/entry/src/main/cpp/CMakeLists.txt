# Superconnect native module (HarmonyOS NEXT, API 12+).
# DevEco generates/maintains the linkage when you add C++ to the module; this
# file lists the sources and the OH NDK libraries the decoder needs.
cmake_minimum_required(VERSION 3.5.0)
project(superconnect)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(superconnect SHARED
    napi_init.cpp
    video_decoder.cpp
)

target_link_libraries(superconnect PUBLIC
    libace_napi.z.so          # napi
    libace_ndk.z.so           # XComponent (OH_NativeXComponent)
    libnative_window.so       # OHNativeWindow
    libnative_media_codecbase.so
    libnative_media_core.so   # OH_AVBuffer / OH_AVFormat
    libnative_media_vdec.so   # OH_VideoDecoder
    libhilog_ndk.z.so
)
