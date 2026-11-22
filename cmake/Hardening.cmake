include(CheckCXXCompilerFlag)
include(CheckPIESupported)

macro(
  myproject_enable_hardening
  target
  global
  ubsan_minimal_runtime)

  message(STATUS "** Enabling Hardening (Target ${target}) **")

  set(NEW_COMPILE_OPTIONS "")
  set(NEW_LINK_OPTIONS "")
  set(NEW_CXX_DEFINITIONS "")

  if(MSVC)
    list(
      APPEND
      NEW_COMPILE_OPTIONS
      /sdl
      /guard:cf)
    # The compiler's /guard:cf only instruments; the linker's sets the image's CFG bit (CON290: BB shipped without it).
    list(
      APPEND
      NEW_LINK_OPTIONS
      /NXCOMPAT
      /DYNAMICBASE
      /guard:cf)
    # An ARM64 link refuses /CETCOMPAT; a Windows cross build names its target via Get-CMakeCrossArgs.
    if(NOT
       CMAKE_SYSTEM_PROCESSOR
       MATCHES
       "^([Aa][Rr][Mm]64|aarch64)$")
      list(APPEND NEW_LINK_OPTIONS /CETCOMPAT)
    endif()
    message(STATUS "*** MSVC flags: /sdl /guard:cf; link: ${NEW_LINK_OPTIONS}")

  elseif(CMAKE_CXX_COMPILER_ID MATCHES ".*Clang|GNU")
    list(APPEND NEW_CXX_DEFINITIONS -D_GLIBCXX_ASSERTIONS)
    message(STATUS "*** GLIBC++ Assertions (vector[], string[], ...) enabled")

    list(
      APPEND
      NEW_COMPILE_OPTIONS
      -U_FORTIFY_SOURCE
      -D_FORTIFY_SOURCE=3)
    message(STATUS "*** g++/clang _FORTIFY_SOURCE=3 enabled")

    check_cxx_compiler_flag(-fstack-protector-strong STACK_PROTECTOR)
    if(STACK_PROTECTOR)
      list(APPEND NEW_COMPILE_OPTIONS -fstack-protector-strong)
      message(STATUS "*** g++/clang -fstack-protector-strong enabled")
    else()
      message(STATUS "*** g++/clang -fstack-protector-strong NOT enabled (not supported)")
    endif()

    check_cxx_compiler_flag(-fcf-protection CF_PROTECTION)
    if(CF_PROTECTION)
      list(APPEND NEW_COMPILE_OPTIONS -fcf-protection)
      message(STATUS "*** g++/clang -fcf-protection enabled")
    else()
      message(STATUS "*** g++/clang -fcf-protection NOT enabled (not supported)")
    endif()

    check_cxx_compiler_flag(-fstack-clash-protection CLASH_PROTECTION)
    if(CLASH_PROTECTION)
      if(LINUX OR CMAKE_CXX_COMPILER_ID MATCHES "GNU")
        list(APPEND NEW_COMPILE_OPTIONS -fstack-clash-protection)
        message(STATUS "*** g++/clang -fstack-clash-protection enabled")
      else()
        message(STATUS "*** g++/clang -fstack-clash-protection NOT enabled (clang on non-Linux)")
      endif()
    else()
      message(STATUS "*** g++/clang -fstack-clash-protection NOT enabled (not supported)")
    endif()

    # A Linux image is PIE with an eagerly bound, read-only GOT (CON294: BeschleunigerBallett linked with neither).
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
      get_property(_hardening_languages GLOBAL PROPERTY ENABLED_LANGUAGES)
      list(
        FILTER
        _hardening_languages
        INCLUDE
        REGEX
        "^(C|CXX)$")
      if(_hardening_languages)
        check_pie_supported(LANGUAGES ${_hardening_languages})
      endif()
      set(CMAKE_POSITION_INDEPENDENT_CODE ON)
      list(
        APPEND
        NEW_LINK_OPTIONS
        -Wl,-z,relro
        -Wl,-z,now)
      message(STATUS "*** g++/clang PIE and -z relro -z now enabled")
    endif()
  endif()

  if(${ubsan_minimal_runtime})
    check_cxx_compiler_flag("-fsanitize=undefined -fno-sanitize-recover=undefined -fsanitize-minimal-runtime"
                            MINIMAL_RUNTIME)
    if(MINIMAL_RUNTIME)

      list(
        APPEND
        NEW_COMPILE_OPTIONS
        -fsanitize=undefined
        -fsanitize-minimal-runtime)
      list(
        APPEND
        NEW_LINK_OPTIONS
        -fsanitize=undefined
        -fsanitize-minimal-runtime)

      if(NOT ${global})
        list(APPEND NEW_COMPILE_OPTIONS -fno-sanitize-recover=undefined)
        list(APPEND NEW_LINK_OPTIONS -fno-sanitize-recover=undefined)
      else()
        message(STATUS "** not enabling -fno-sanitize-recover=undefined for global consumption")
      endif()

      message(STATUS "*** ubsan minimal runtime enabled")
    else()
      message(STATUS "*** ubsan minimal runtime NOT enabled (not supported)")
    endif()
  else()
    message(STATUS "*** ubsan minimal runtime NOT enabled (not requested)")
  endif()

  message(STATUS "** Hardening Compiler Flags: ${NEW_COMPILE_OPTIONS}")
  message(STATUS "** Hardening Linker Flags: ${NEW_LINK_OPTIONS}")
  message(STATUS "** Hardening Compiler Defines: ${NEW_CXX_DEFINITIONS}")

  if(${global})
    message(STATUS "** Setting hardening options globally for all dependencies")
    # A flags variable is one string: a list's semicolons there would end the compiler's command line.
    list(
      JOIN
      NEW_COMPILE_OPTIONS
      " "
      _hardening_compile_flags)
    list(
      JOIN
      NEW_CXX_DEFINITIONS
      " "
      _hardening_definitions)
    list(
      JOIN
      NEW_LINK_OPTIONS
      " "
      _hardening_link_flags)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${_hardening_compile_flags} ${_hardening_definitions}")
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${_hardening_link_flags}")
  else()
    target_compile_options(${target} INTERFACE ${NEW_COMPILE_OPTIONS})
    target_link_options(${target} INTERFACE ${NEW_LINK_OPTIONS})
    target_compile_definitions(${target} INTERFACE ${NEW_CXX_DEFINITIONS})
  endif()
endmacro()
