#!/bin/bash
set -euo pipefail
vm=$(/usr/bin/vm_stat | /usr/bin/awk '
  NR == 1 && $(NF-1) ~ /^[0-9]+$/ { printf "page_bytes=%s ", $(NF-1) }
  /^Pages free:/ { free=$NF+0 }
  /^Pages speculative:/ { speculative=$NF+0 }
  /^Pages wired down:/ { wired=$NF+0 }
  /^Pages occupied by compressor:/ { compressed=$NF+0 }
  /^Swapouts:/ { swapouts=$NF+0 }
  END { printf "free_pages=%d speculative_pages=%d wired_pages=%d compressor_pages=%d swapouts=%d",free,speculative,wired,compressed,swapouts }
') || vm=vm=unavailable
swap=$(/usr/sbin/sysctl -n vm.swapusage | /usr/bin/awk '$4=="used" && $6 ~ /^[0-9]+([.][0-9]+)?[KMG]$/ {printf "swap_used=%s",$6}') || swap=swap=unavailable
disk=$(/bin/df -Pk "${RUNNER_TEMP:-.}" | /usr/bin/awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "disk_free_kib=%s",$4}') || disk=disk=unavailable
rss=$(/bin/ps -ax -o rss= -o comm= | /usr/bin/awk '
  $1 ~ /^[0-9]+$/ && $NF ~ /(^|\/)AppKitTestHost$/ { hosts++; appkit+=$1 }
  $1 ~ /^[0-9]+$/ && $NF ~ /(^|\/)(swift-frontend|clang(-[0-9]+)?)$/ { compilers++; compile+=$1 }
  END { printf "appkit_processes=%d appkit_rss_kib=%d compiler_processes=%d compiler_rss_kib=%d",hosts,appkit,compilers,compile }
') || rss=rss=unavailable
printf 'FLECK_RUNNER_RESOURCES %s %s %s %s\n' "$vm" "${swap:-swap=unavailable}" "${disk:-disk=unavailable}" "$rss"
