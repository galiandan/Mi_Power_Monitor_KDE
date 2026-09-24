cmake_minimum_required(VERSION 3.16)
project(Mi_Power_Monitor_KDE)

find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

find_package(KF6 REQUIRED COMPONENTS Package)
plasma_install_package(. com.github.galiandan.mipowermonitor)
