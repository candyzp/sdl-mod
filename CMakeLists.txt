cmake_minimum_required(VERSION 3.21)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "iOS" OR IOS)
    set(CMAKE_OSX_ARCHITECTURES "arm64")
else()
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
endif()

project(sdl-mod VERSION 1.0.7)

if (NOT DEFINED ENV{GEODE_SDK})
    message(FATAL_ERROR "Unable to find Geode SDK! Please define GEODE_SDK environment variable to point to Geode")
else()
    message(STATUS "Found Geode: $ENV{GEODE_SDK}")
endif()

add_subdirectory($ENV{GEODE_SDK} ${CMAKE_CURRENT_BINARY_DIR}/geode)

if (CMAKE_SYSTEM_NAME STREQUAL "iOS" OR IOS)
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 23)
    set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

    add_library(${PROJECT_NAME} SHARED
        src/ios/ios_display_link.mm
    )
    target_link_libraries(${PROJECT_NAME}
        "-framework Foundation"
        "-framework UIKit"
        "-framework QuartzCore"
    )
else()
    add_library(${PROJECT_NAME} SHARED
        src/main.mm
        src/input.cpp
        src/hooks.cpp
        src/keymap.cpp
        src/events.cpp
    )

    set_source_files_properties(
        src/main.mm
        PROPERTIES SKIP_PRECOMPILE_HEADERS ON
    )

    CPMAddPackage(
        name SDL3
        GITHUB_REPOSITORY libsdl-org/SDL
        GIT_TAG release-3.4.16
        PATCHES "cmake/sdl-add-colorspace-hint.patch"
        OPTIONS
            "SDL_AUDIO OFF"
            "SDL_GPU OFF"
            "SDL_RENDER OFF"
            "SDL_CAMERA OFF"
            "SDL_HAPTIC OFF"
            "SDL_POWER OFF"
            "SDL_SENSOR OFF"
            "SDL_DIALOG OFF"
            "SDL_TRAY OFF"
            "SDL_VULKAN OFF"
            "SDL_METAL OFF"
            "SDL_OPENGLES OFF"
    )

    target_link_libraries(${PROJECT_NAME} SDL3::SDL3-static)
endif()

setup_geode_mod(${PROJECT_NAME})

# Geode 5.11.2's generated bindings use FMOD types without including FMOD's
# declarations in GeneratedSource.cpp. Force-include the SDK's public FMOD
# compatibility header for the generated bindings target (iOS and other
# targets), matching the SDK's expected build environment.
if (TARGET GeodeBindings)
    target_compile_options(GeodeBindings PRIVATE
        "SHELL:-include Geode/fmod/fmod.h"
    )
endif()
