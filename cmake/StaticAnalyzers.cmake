function(
  myproject_cppcheck_is_usable
  CPPCHECK_EXECUTABLE
  OUT_IS_USABLE
  OUT_ERROR)
  set(CPPCHECK_SMOKE_FILE "${CMAKE_BINARY_DIR}/cppcheck-smoke.cpp")
  file(WRITE "${CPPCHECK_SMOKE_FILE}" "int main(){return 0;}\n")

  execute_process(
    COMMAND ${CPPCHECK_EXECUTABLE} --template=gcc --enable=style --std=c++${CMAKE_CXX_STANDARD} "${CPPCHECK_SMOKE_FILE}"
    RESULT_VARIABLE CPPCHECK_SMOKE_RESULT
    OUTPUT_VARIABLE CPPCHECK_SMOKE_STDOUT
    ERROR_VARIABLE CPPCHECK_SMOKE_STDERR
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_STRIP_TRAILING_WHITESPACE)

  if(CPPCHECK_SMOKE_RESULT EQUAL 0)
    set(${OUT_IS_USABLE}
        TRUE
        PARENT_SCOPE)
    set(${OUT_ERROR}
        ""
        PARENT_SCOPE)
  else()
    set(CPPCHECK_SMOKE_MESSAGE "${CPPCHECK_SMOKE_STDERR}")
    if(CPPCHECK_SMOKE_MESSAGE STREQUAL "")
      set(CPPCHECK_SMOKE_MESSAGE "${CPPCHECK_SMOKE_STDOUT}")
    endif()

    set(${OUT_IS_USABLE}
        FALSE
        PARENT_SCOPE)
    set(${OUT_ERROR}
        "${CPPCHECK_SMOKE_MESSAGE}"
        PARENT_SCOPE)
  endif()
endfunction()

macro(myproject_enable_cppcheck WARNINGS_AS_ERRORS CPPCHECK_OPTIONS)
  set(_MYPROJECT_ENABLE_CPPCHECK TRUE)

  if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
    message(STATUS "Skipping cppcheck for clang-cl toolchains.")
    unset(CMAKE_CXX_CPPCHECK)
    set(_MYPROJECT_ENABLE_CPPCHECK FALSE)
  endif()

  find_program(CPPCHECK cppcheck)
  if(_MYPROJECT_ENABLE_CPPCHECK AND CPPCHECK)
    myproject_cppcheck_is_usable(${CPPCHECK} CPPCHECK_IS_USABLE CPPCHECK_ERROR_MESSAGE)
    if(NOT CPPCHECK_IS_USABLE)
      message(
        WARNING
          "cppcheck requested but disabled because the detected installation is unusable: ${CPPCHECK_ERROR_MESSAGE}")
      unset(CMAKE_CXX_CPPCHECK)
      set(_MYPROJECT_ENABLE_CPPCHECK FALSE)
    endif()

    if(_MYPROJECT_ENABLE_CPPCHECK)

      if(CMAKE_GENERATOR MATCHES ".*Visual Studio.*")
        set(CPPCHECK_TEMPLATE "vs")
      else()
        set(CPPCHECK_TEMPLATE "gcc")
      endif()

      if("${CPPCHECK_OPTIONS}" STREQUAL "")
        # Enable all warnings that are actionable by the user of this toolset
        # style should enable the other 3, but we'll be explicit just in case
        set(SUPPRESS_DIR "*:${CMAKE_CURRENT_BINARY_DIR}/_deps/*.h")
        message(STATUS "CPPCHECK_OPTIONS suppress: ${SUPPRESS_DIR}")
        # Keep this list analysis-only: --check-config validates the config and analyses nothing,
        # so adding it here turns the whole gate into a no-op (AccelerANTgine, 2026-09).
        set(CMAKE_CXX_CPPCHECK
            ${CPPCHECK}
            --template=${CPPCHECK_TEMPLATE}
            --enable=style,performance,warning,portability
            --inline-suppr
            # We cannot act on a bug/missing feature of cppcheck
            --suppress=cppcheckError
            --suppress=internalAstError
            # if a file does not have an internalAstError, we get an unmatchedSuppression error
            --suppress=unmatchedSuppression
            # noisy and incorrect sometimes
            --suppress=passedByValue
            # ignores code that cppcheck thinks is invalid C++
            --suppress=syntaxError
            --suppress=preprocessorErrorDirective
            --inconclusive
            --suppress=${SUPPRESS_DIR})
      else()
        # if the user provides a CPPCHECK_OPTIONS with a template specified, it will override this template
        set(CMAKE_CXX_CPPCHECK ${CPPCHECK} --template=${CPPCHECK_TEMPLATE} ${CPPCHECK_OPTIONS})
      endif()

      if(NOT
         "${CMAKE_CXX_STANDARD}"
         STREQUAL
         "")
        set(CMAKE_CXX_CPPCHECK ${CMAKE_CXX_CPPCHECK} --std=c++${CMAKE_CXX_STANDARD})
      endif()
      if(${WARNINGS_AS_ERRORS})
        list(APPEND CMAKE_CXX_CPPCHECK --error-exitcode=2)
      endif()
    endif()
  else()
    if(_MYPROJECT_ENABLE_CPPCHECK)
      message(WARNING "cppcheck requested but executable not found - cppcheck is disabled for this build")
    endif()
  endif()
endmacro()

macro(myproject_enable_clang_tidy target WARNINGS_AS_ERRORS)
  # Optional 3rd argument: a --header-filter regex (AccelerANTgine passes "Src/.*").
  # Absent or empty appends nothing, so the consumer's .clang-tidy HeaderFilterRegex decides.
  set(CLANG_TIDY_HEADER_FILTER "")
  if(${ARGC} GREATER 2)
    set(CLANG_TIDY_HEADER_FILTER "${ARGV2}")
  endif()

  find_program(CLANGTIDY clang-tidy)
  if(CLANGTIDY)
    if(NOT
       CMAKE_CXX_COMPILER_ID
       MATCHES
       ".*Clang")

      get_target_property(TARGET_PCH ${target} INTERFACE_PRECOMPILE_HEADERS)

      if("${TARGET_PCH}" STREQUAL "TARGET_PCH-NOTFOUND")
        get_target_property(TARGET_PCH ${target} PRECOMPILE_HEADERS)
      endif()

      if(NOT ("${TARGET_PCH}" STREQUAL "TARGET_PCH-NOTFOUND"))
        message(
          SEND_ERROR
            "clang-tidy cannot be enabled with non-clang compiler and PCH, clang-tidy fails to handle gcc's PCH file")
      endif()
    endif()

    # construct the clang-tidy command line
    # Report-only gate: never add --fix here - it rewrites sources mid-build (autofix belongs in scripts).
    set(CLANG_TIDY_OPTIONS
        ${CLANGTIDY}
        -extra-arg=-Wno-unknown-warning-option
        -extra-arg=-Wno-ignored-optimization-argument
        -extra-arg=-Wno-unused-command-line-argument
        -checks=-misc-include-cleaner)
    if(NOT
       "${CLANG_TIDY_HEADER_FILTER}"
       STREQUAL
       "")
      list(APPEND CLANG_TIDY_OPTIONS --header-filter=${CLANG_TIDY_HEADER_FILTER})
    endif()
    list(APPEND CLANG_TIDY_OPTIONS -p)
    # set standard
    if(NOT
       "${CMAKE_CXX_STANDARD}"
       STREQUAL
       "")
      if("${CLANG_TIDY_OPTIONS_DRIVER_MODE}" STREQUAL "cl")
        set(CLANG_TIDY_OPTIONS ${CLANG_TIDY_OPTIONS} -extra-arg=/std:c++${CMAKE_CXX_STANDARD})
      else()
        set(CLANG_TIDY_OPTIONS ${CLANG_TIDY_OPTIONS} -extra-arg=-std=c++${CMAKE_CXX_STANDARD})
      endif()
    endif()

    # set warnings as errors
    if(${WARNINGS_AS_ERRORS})
      list(APPEND CLANG_TIDY_OPTIONS -warnings-as-errors=*)
    endif()

    message("Also setting clang-tidy globally")
    set(CMAKE_CXX_CLANG_TIDY ${CLANG_TIDY_OPTIONS})
  else()
    message(WARNING "clang-tidy requested but executable not found - clang-tidy is disabled for this build")
  endif()
endmacro()
