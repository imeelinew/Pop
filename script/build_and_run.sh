#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
mode="${1:-run}"
case "$mode" in
    run|--verify|--debug|--logs|--telemetry) ;;
    *) print -u2 'Usage: script/build_and_run.sh [--verify|--debug|--logs|--telemetry]'; exit 2 ;;
esac
"$repo_root/scripts/install.sh" --no-open
case "$mode" in
    --debug) /usr/bin/lldb -- /Applications/Pop.app/Contents/MacOS/Pop ;;
    --logs|--telemetry)
        /usr/bin/open /Applications/Pop.app
        /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.eli.Pop"'
        ;;
    --verify)
        /usr/bin/open /Applications/Pop.app
        /bin/sleep 1
        /usr/bin/pgrep -x Pop >/dev/null
        print 'Pop is running'
        ;;
    run) /usr/bin/open /Applications/Pop.app ;;
esac
