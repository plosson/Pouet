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

assert_no_force_kill() {
    ! rg -n 'killall -9 coreaudiod' Makefile Sources/Pouet/UI/ContentView.swift >/dev/null
}

assert_uses_graceful_restart() {
    rg -n 'launchctl kickstart -kp system/com.apple.audio.coreaudiod' \
        Installer/scripts/postinstall \
        Uninstaller/uninstall.sh \
        Sources/Pouet/UI/ContentView.swift \
        Makefile >/dev/null
}

echo "=== Install Script Safety Tests ==="
run_test "test_no_forceful_coreaudiod_kill" assert_no_force_kill
run_test "test_uses_graceful_coreaudiod_restart" assert_uses_graceful_restart

echo
echo "${tests_passed}/${tests_run} install script tests passed"
[ "${tests_passed}" -eq "${tests_run}" ]
