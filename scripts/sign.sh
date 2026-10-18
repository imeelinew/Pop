#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
# Override if the mac-sign plugin is installed elsewhere. / 插件位置不同时可覆盖此路径。
signer="${POP_SIGNER:-/Users/eli/.codex/plugins/cache/openai-curated-remote/ai-mac-sign/0.2.0/skills/mac-sign/scripts/mac_sign.py}"
if [[ ! -f "$signer" ]]; then
    print -u2 'mac-sign is unavailable. Set POP_SIGNER to mac_sign.py.'
    exit 1
fi
python3 "$signer" sign --project "$repo_root" --app "$1" --report "$2"
