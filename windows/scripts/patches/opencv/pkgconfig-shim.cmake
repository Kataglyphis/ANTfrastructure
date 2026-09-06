# CMAKE_PROJECT_INCLUDE shim: give OpenCV a working pkg-config on Windows.
#
# WHY (backlog #94). OpenCV's videoio can link a system FFmpeg through
# pkg-config, but the route is gated in
# modules/videoio/cmake/detect_ffmpeg.cmake (5.0.0) by:
#
#     if(NOT HAVE_FFMPEG AND PKG_CONFIG_FOUND)
#       ocv_check_modules(FFMPEG libavcodec libavformat libavutil libswscale)
#
# PKG_CONFIG_FOUND comes from find_package(PkgConfig), which OpenCV only runs on
# UNIX. On Windows the variable is therefore never set, the branch never fires,
# and OpenCV falls back to downloading its own prebuilt FFmpeg — which is how
# this image ended up carrying avcodec 61 inside OpenCV while the chain builds
# avcodec 63, with cv::VideoCapture on the older one.
#
# Simply passing -DOPENCV_FFMPEG_SKIP_DOWNLOAD=ON does NOT fix that: it removes
# the download without enabling any replacement, and the measured result was a
# flat `FFMPEG: NO` — strictly worse. That attempt is recorded in #94; do not
# repeat it without this shim.
#
# CMake includes this file immediately after every project() call, i.e. before
# the videoio module is configured, so PKG_CONFIG_FOUND and the pkg_check_modules
# macro are in scope by the time detect_ffmpeg.cmake runs. find_package(PkgConfig)
# is idempotent and cheap, so being included for nested 3rdparty project() calls
# as well is harmless.
#
# VERIFIED inside bk-windows-media-core before wiring this
# (Test-OpencvVideoBackends.ps1, the "#94 route test" section):
#     PKG_CONFIG_FOUND=TRUE
#     FFMPEG_FOUND=1   FFMPEG_libavcodec_VERSION=63.1.100
#     FFMPEG_INCLUDE_DIRS=C:/runtime/ffmpeg/include
#     FFMPEG_LIBRARY_DIRS=C:/runtime/ffmpeg/lib
#     FFMPEG_LIBRARIES=avcodec;avformat;avutil;swscale
# Note the instrument: CMake's own pkg_check_modules, not a shell `pkg-config`
# call. The shell answer was already yes while OpenCV still configured NO — the
# earlier regression came from testing the wrong layer.
find_package(PkgConfig)
if(PKG_CONFIG_FOUND)
  message(STATUS "pkgconfig-shim: PkgConfig available (${PKG_CONFIG_EXECUTABLE}) - OpenCV's FFmpeg pkg-config route is unblocked")
else()
  message(WARNING "pkgconfig-shim: find_package(PkgConfig) failed; OpenCV will not detect the chain's FFmpeg (backlog #94)")
endif()
