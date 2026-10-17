#!/usr/bin/env bash
# git-fixture-env.sh — the git environment of the suites that build throwaway remotes: file:// submodules, develop, one identity.
[ -n "${_GIT_FIXTURE_ENV_LOADED:-}" ] && return 0
_GIT_FIXTURE_ENV_LOADED=1
export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_CONFIG_KEY_1=init.defaultBranch GIT_CONFIG_VALUE_1=develop
export GIT_CONFIG_KEY_2=advice.detachedHead GIT_CONFIG_VALUE_2=false
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
