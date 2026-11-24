#!/usr/bin/env bash
# Печатает версию (--version) или описание релиза для верхней версии CHANGELOG.md
set -euo pipefail
cl=${CHANGELOG:-CHANGELOG.md}
ver=$(grep -m1 -oP '^## \[\K[0-9]+\.[0-9]+\.[0-9]+(?=\])' "$cl")
if [[ ${1-} == --version ]]; then echo "$ver"; exit 0; fi
repo=${GITHUB_REPOSITORY:-cybermind-off/tg-ws-proxy-corp}
awk -v v="$ver" '
  $0 ~ "^## \\[" v "\\]" {on=1; next}
  on && /^## \[/ {exit}
  on {print}
' "$cl" | sed -e '/./,$!d'
cat <<EOF

### Установка
\`\`\`bash
git clone https://github.com/$repo.git
cd ${repo#*/} && chmod +x *.sh
\`\`\`
Подробная инструкция — в [README](https://github.com/$repo#readme).

---
TG WS Proxy Corp — автор Cybermind. Прокси: [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) © Flowseal (MIT).
EOF
