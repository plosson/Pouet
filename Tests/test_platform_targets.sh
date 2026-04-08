#!/bin/bash
set -euo pipefail

tests_run=0
tests_passed=0

run_test() {
    local name="$1"
    shift
    tests_run=$((tests_run + 1))
    printf "  %-60s" "$name"
    if "$@"; then
        echo "OK"
        tests_passed=$((tests_passed + 1))
    else
        echo "FAIL"
    fi
}

assert_package_targets_macos15() {
    rg -n 'platforms: \[\.macOS\("15\.0"\)\]' Package.swift >/dev/null
}

assert_makefile_targets_macos15() {
    rg -n -- '-mmacosx-version-min=15\.0' Makefile >/dev/null
}

assert_plists_target_macos15() {
    rg -n '<string>15\.0</string>' App/Info.plist Uninstaller/Info.plist >/dev/null
}

assert_ci_uses_macos15() {
    rg -n 'runs-on: macos-15' .github/workflows/build.yml >/dev/null
}

echo "=== Platform Target Tests ==="
run_test "test_package_targets_macos15" assert_package_targets_macos15
run_test "test_makefile_targets_macos15" assert_makefile_targets_macos15
run_test "test_plists_target_macos15" assert_plists_target_macos15
run_test "test_ci_uses_macos15" assert_ci_uses_macos15

echo
echo "${tests_passed}/${tests_run} platform target tests passed"
[ "${tests_passed}" -eq "${tests_run}" ]
