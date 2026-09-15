cmake_minimum_required(VERSION 3.5.0)
project(vntc)

set(CMAKE_CXX_STANDARD 17)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${NATIVERENDER_ROOT_PATH}/include)

if(NOT DEFINED OHOS_ARCH OR OHOS_ARCH STREQUAL "")
  set(OHOS_ARCH arm64-v8a)
endif()

# vnt core (libvnt_ffi_v1.so / libvnt_ffi_v2.so) is loaded at runtime
# via dlopen in napi_init.cpp; no link-time dependency here.

add_library(vnt_napi SHARED napi_init.cpp)
target_link_libraries(vnt_napi PUBLIC libace_napi.z.so libhilog_ndk.z.so)
