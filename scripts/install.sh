#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
installed_app="/Applications/Pop.app"
mode="${1:-run}"
case "$mode" in
    run|--no-open) ;;
    *) print -u2 'Usage: scripts/install.sh [--no-open]'; exit 2 ;;
esac

print 'Building Pop (Release)'
/usr/bin/xcodebuild -quiet -project "$repo_root/Pop.xcodeproj" -scheme Pop \
    -configuration Release -destination 'generic/platform=macOS' build
built_app=$(python3 "$script_dir/xcode-path.py" Release)
cache=$(python3 "$script_dir/xcode-path.py" Release --derived-data)
"$script_dir/sign.sh" "$built_app" "$cache/local-signing.json"

stage_dir=$(mktemp -d '/Applications/.Pop-install.XXXXXX')
rollback=0
cleanup() {
    if (( rollback )) && [[ -d "$stage_dir/Previous.app" ]]; then
        [[ ! -e "$installed_app" ]] || /bin/mv "$installed_app" "$stage_dir/Failed.app"
        /bin/mv "$stage_dir/Previous.app" "$installed_app"
    fi
    /bin/rm -rf "$stage_dir"
}
trap cleanup EXIT
/usr/bin/ditto "$built_app" "$stage_dir/Pop.app"
/usr/bin/codesign --verify --all-architectures --deep --strict "$stage_dir/Pop.app"
/usr/bin/pkill -x Pop 2>/dev/null || true
if [[ -e "$installed_app" ]]; then
    /bin/mv "$installed_app" "$stage_dir/Previous.app"
    rollback=1
fi
/bin/mv "$stage_dir/Pop.app" "$installed_app"
/usr/bin/codesign --verify --all-architectures --deep --strict "$installed_app"
rollback=0
print "Installed: $installed_app"
if [[ "$mode" != --no-open ]]; then /usr/bin/open "$installed_app"; fi
