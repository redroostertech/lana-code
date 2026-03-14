cmake_minimum_required(VERSION 3.20)
project(mylib VERSION 0.1.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Library target
add_library(mylib
    src/mylib.c
)

target_include_directories(mylib
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
)

# Install rules
include(GNUInstallDirs)

install(TARGETS mylib
    EXPORT mylibTargets
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

install(DIRECTORY include/mylib
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

install(EXPORT mylibTargets
    FILE mylibTargets.cmake
    NAMESPACE mylib::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/mylib
)

# Testing
option(MYLIB_BUILD_TESTS "Build tests" ON)

if(MYLIB_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
