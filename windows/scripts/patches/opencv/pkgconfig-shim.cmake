# OpenCV runs find_package(PkgConfig) only on UNIX: see docs/windows-builds.md § OpenCV 5.x
find_package(PkgConfig)
if(PKG_CONFIG_FOUND)
  message(STATUS "pkgconfig-shim: PkgConfig available (${PKG_CONFIG_EXECUTABLE}) - OpenCV's FFmpeg pkg-config route is unblocked")
else()
  message(WARNING "pkgconfig-shim: find_package(PkgConfig) failed; OpenCV will not detect the chain's FFmpeg (backlog #94)")
endif()
