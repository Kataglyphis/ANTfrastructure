#!/bin/sh
# CPATH alone cannot repair C++ #include_next with a relocated compiler.
native_gcc_system_paths() {
  _idaf="-idirafter /usr/include"
  [ -z "$1" ] || _idaf="-idirafter $1 ${_idaf}"
  export CPATH="${CPATH:+${CPATH}:}${1:+$1:}/usr/include"
  export CPPFLAGS="${CPPFLAGS:+${CPPFLAGS} }${_idaf}"
  export CFLAGS="${CFLAGS:+${CFLAGS} }${_idaf}"
  export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }${_idaf}"
  export LIBRARY_PATH="${LIBRARY_PATH:+${LIBRARY_PATH}:}${2:+$2:}/usr/lib"
}
