#!/var/jb/bin/sh
# Run as mobile, one bounded phase at a time. Preserve raw output and exit codes.
set -eu
mode=${1:?mode required}
label=${2:?label required}
directory=${3:-/var/mobile/Powercuff-validation}
case "$mode" in off|moderate|heavy) ;; *) echo 'Use off, moderate or heavy' >&2; exit 1 ;; esac
case "$label" in *[!A-Za-z0-9_-]*|'') echo 'Invalid label' >&2; exit 1 ;; esac
ctl=/var/jb/usr/bin/powercuffctl
mkdir -p "$directory/$label"
date -u > "$directory/$label/timestamp.txt"
"$ctl" lpm-only off
"$ctl" mode "$mode"
sleep 15
"$ctl" status > "$directory/$label/status-before.json"
for sample in 1 2 3; do
    "$ctl" benchmark cpu 5 > "$directory/$label/cpu-$sample.json"
done
"$ctl" status > "$directory/$label/status-after.json"
cp /var/jb/var/log/Powercuff/thermalmonitord.json "$directory/$label/daemon.json"
echo "Saved $label ($mode), three five-second CPU samples"
cat "$directory/$label/status-after.json"
