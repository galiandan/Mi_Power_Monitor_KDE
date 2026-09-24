cmake_minimum_required(VERSION 3.16)

project(plasma-applet-mipowermonitor
    VERSION 0.1.0
    DESCRIPTION "KDE Plasma 6 power monitor plasmoid"
    LANGUAGES NONE
)

find_package(ECM REQUIRED NO_MODULE)
list(APPEND CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

find_package(Plasma REQUIRED)
plasma_install_package(package com.github.galiandan.mipowermonitor)

# Build a KDE Store compatible archive containing only the Plasmoid package.
add_custom_target(package-plasmoid
    COMMAND ${CMAKE_COMMAND} -E tar cf
        "${CMAKE_BINARY_DIR}/com.github.galiandan.mipowermonitor.zip"
        --format=zip -- .
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/package"
    COMMENT "Creating Plasma widget package"
    VERBATIM
)
