#!/bin/bash
# Claude Code status line; receives session JSON on stdin.
# Fields: https://code.claude.com/docs/en/statusline
input=$(cat)

cwd=$(jq -r '.cwd' <<<"$input")
model=$(jq -r '.model.display_name // "?"' <<<"$input")
ctx=$(jq -r '.context_window.used_percentage // 0 | round' <<<"$input")
# Subscription usage limits: absent before the first API response of a
# session, and entirely absent on API/Bedrock billing.
session=$(jq -r '.rate_limits.five_hour.used_percentage // empty | round' <<<"$input")
session_reset=$(jq -r '.rate_limits.five_hour.resets_at // empty | round' <<<"$input")
week=$(jq -r '.rate_limits.seven_day.used_percentage // empty | round' <<<"$input")
week_reset=$(jq -r '.rate_limits.seven_day.resets_at // empty | round' <<<"$input")
# Time spent awaiting API responses; zero until the first one lands, which is
# when missing usage limits stop being expected and start being a warning.
api_ms=$(jq -r '.cost.total_api_duration_ms // 0 | round' <<<"$input")

branch=$(cd "$cwd" 2>/dev/null && git -c core.useReplaceRefs=false branch 2>/dev/null | grep '^\*' | sed 's/^\* //')

# Display only; must stay after the cd above (a literal ~ doesn't expand).
[[ "$cwd" == "$HOME" || "$cwd" == "$HOME"/* ]] && cwd="~${cwd#"$HOME"}"

# Time until the given epoch, as the two largest applicable units
# (3d6h / 2h13m / 42m); nothing if already past.
eta() {
  local rem=$(( $1 - $(date +%s) ))
  [ "$rem" -le 0 ] && return
  local d=$(( rem / 86400 )) h=$(( rem % 86400 / 3600 )) m=$(( rem % 3600 / 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"
  fi
}

# Label, percentage in yellow turning red at >= 80, and optionally a
# countdown to the reset epoch in $3.
pct() {
  local colour='\033[33m'
  [ "$2" -ge 80 ] && colour='\033[31m'
  printf "%s ${colour}%s%%\033[0m" "$1" "$2"
  if [ -n "$3" ]; then
    local countdown
    countdown=$(eta "$3")
    [ -n "$countdown" ] && printf ' (%s)' "$countdown"
  fi
}

printf '\033[36m%s\033[0m' "$cwd"
[ -n "$branch" ] && printf ' | \033[32m%s\033[0m' "$branch"
printf ' | \033[35m%s\033[0m | ' "$model"
pct $'\033[38;2;88;105;246mcontext\033[0m' "$ctx"
if [ -n "$session" ]; then printf ' | '; pct session "$session" "$session_reset"; fi
if [ -n "$week" ]; then printf ' | '; pct week "$week" "$week_reset"; fi
# No usage buckets once a response has landed means this session isn't billed
# to a Pro/Max subscription, but to an API key, Bedrock or Vertex.
if [ -z "$session" ] && [ -z "$week" ] && [ "$api_ms" -gt 0 ]; then
  printf ' | \033[1;31mNOT USING CONSUMER SUBSCRIPTION\033[0m'
fi
