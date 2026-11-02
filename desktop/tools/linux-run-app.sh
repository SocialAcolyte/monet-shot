#!/usr/bin/env bash
# Inside the run container: (re)start the app with extra env and args, wait,
# screenshot. linux-run-app.sh <shot name> <wait s> [VAR=value ...] [-- app args]
set -euo pipefail
name=$1 wait=$2; shift 2
envs=(); while (( $# )) && [[ $1 != -- ]]; do envs+=("$1"); shift; done; [[ ${1:-} == -- ]] && shift
pkill -x monet-shot-prod 2>/dev/null || true; pkill -x monet-shot 2>/dev/null || true; sleep 1
. /tmp/dbus.env
export DISPLAY=:99 MONETSHOT_HOME=/home/run
bin=${BIN:-/target/monet-shot-prod}
(env "${envs[@]}" "$bin" "$@" >> /tmp/app.log 2>&1 &)
sleep "$wait"
bash /src/desktop/tools/linux-run-shot.sh "$name"
