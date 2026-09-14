#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source=$repo_dir/deploy/pinephone/openrc-device-root
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM

helper=$fixture/emacsos-openrc-device
lock=$fixture/device.lock
backlight_dir=$fixture/backlight-device
torch_dir=$fixture/torch-device
torch_parent=$fixture/torch-parent
driver=$fixture/sgm3140
backlight=$backlight_dir/brightness
backlight_max_file=$backlight_dir/max_brightness
torch=$torch_dir/brightness
torch_max_file=$torch_dir/max_brightness
owner=$(id -un)
group=$(id -gn)
uid=$(id -u)

mkdir -p "$backlight_dir/power" "$torch_dir/power" "$torch_parent" "$driver"
ln -s "$torch_parent" "$torch_dir/device"
ln -s "$driver" "$torch_parent/driver"
printf '%s\n' 1562 >"$backlight"
printf '%s\n' 3124 >"$backlight_max_file"
printf '%s\n' 0 >"$torch"
printf '%s\n' 1 >"$torch_max_file"
chmod 0755 "$backlight_dir" "$torch_dir"
chmod 0644 "$backlight"
chmod 0444 "$backlight_max_file" "$torch_max_file"
chmod 0664 "$torch"

sed \
    -e "s|/usr/local/sbin/emacsos-openrc-device|$helper|g" \
    -e "s|/run/emacsos-openrc-device.lock|$lock|g" \
    -e "s|expected_uid=0|expected_uid=$uid|" \
    -e "s|root_owner=root|root_owner=$owner|" \
    -e "s|root_group=root|root_group=$group|" \
    -e "s|torch_brightness_group=feedbackd|torch_brightness_group=$group|" \
    -e "s|backlight_dir=/sys/devices/platform/backlight/backlight/backlight|backlight_dir=$backlight_dir|" \
    -e "s|torch_dir=/sys/devices/platform/led-controller/leds/white:flash|torch_dir=$torch_dir|" \
    -e "s|torch_driver=/sys/bus/platform/drivers/sgm3140|torch_driver=$driver|" \
    "$source" >"$helper"
chmod 0755 "$helper"

[ "$("$helper" status)" = 'brightness:50
flashlight:off' ]

for level in 25 50 75 100; do
    case $level in
        25) raw=781 ;;
        50) raw=1562 ;;
        75) raw=2343 ;;
        100) raw=3124 ;;
    esac
    [ "$("$helper" brightness "$level")" = "brightness:$level
flashlight:off" ]
    [ "$(cat "$backlight")" = "$raw" ]
done

[ "$("$helper" flashlight on)" = 'brightness:100
flashlight:on' ]
[ "$(cat "$torch")" = 1 ]
[ "$("$helper" flashlight off)" = 'brightness:100
flashlight:off' ]
[ "$(cat "$torch")" = 0 ]

printf '%s\n' 2 >"$torch"
before=$(cat "$backlight")
if "$helper" brightness 25 >/dev/null 2>&1; then
    printf '%s\n' 'brightness changed while flashlight state was invalid' >&2
    exit 1
fi
[ "$(cat "$backlight")" = "$before" ]
printf '%s\n' 0 >"$torch"

before=$(sha256sum "$backlight" "$torch")
for args in 'brightness 0' 'brightness 80' 'flashlight toggle' \
    'status extra' 'unknown' 'brightness'; do
    if "$helper" $args >/dev/null 2>&1; then
        printf 'unsafe device operation was accepted: %s\n' "$args" >&2
        exit 1
    fi
    [ "$(sha256sum "$backlight" "$torch")" = "$before" ]
done

chmod 0644 "$backlight_max_file"
printf '%s\n' 3123 >"$backlight_max_file"
chmod 0444 "$backlight_max_file"
if "$helper" status >/dev/null 2>&1; then
    printf '%s\n' 'changed backlight maximum was accepted' >&2
    exit 1
fi
chmod 0644 "$backlight_max_file"
printf '%s\n' 3124 >"$backlight_max_file"
chmod 0444 "$backlight_max_file"

chmod 0600 "$torch"
if "$helper" status >/dev/null 2>&1; then
    printf '%s\n' 'changed device metadata was accepted' >&2
    exit 1
fi
chmod 0664 "$torch"

chmod 0775 "$torch_dir"
if "$helper" status >/dev/null 2>&1; then
    printf '%s\n' 'changed device directory metadata was accepted' >&2
    exit 1
fi
chmod 0755 "$torch_dir"

mv "$torch_max_file" "$fixture/torch-max-missing"
if "$helper" status >/dev/null 2>&1; then
    printf '%s\n' 'missing device file was accepted' >&2
    exit 1
fi
mv "$fixture/torch-max-missing" "$torch_max_file"

wrong_driver=$fixture/wrong-driver
mkdir "$wrong_driver"
rm "$torch_parent/driver"
ln -s "$wrong_driver" "$torch_parent/driver"
if "$helper" status >/dev/null 2>&1; then
    printf '%s\n' 'changed flashlight driver was accepted' >&2
    exit 1
fi
rm "$torch_parent/driver"
ln -s "$driver" "$torch_parent/driver"

mv "$torch" "$fixture/torch-real"
ln -s "$fixture/torch-real" "$torch"
if "$helper" status >/dev/null 2>&1; then
    printf '%s\n' 'symlinked device path was accepted' >&2
    exit 1
fi
rm "$torch"
mv "$fixture/torch-real" "$torch"

wrong_uid=$((uid + 1))
sed "s|expected_uid=$uid|expected_uid=$wrong_uid|" "$helper" >"$fixture/wrong-uid"
chmod 0755 "$fixture/wrong-uid"
if "$fixture/wrong-uid" --worker status >/dev/null 2>&1; then
    printf '%s\n' 'wrong helper UID was accepted' >&2
    exit 1
fi

exec 8>"$lock"
flock -x 8
chmod 0644 "$backlight_max_file"
printf '%s\n' 3123 >"$backlight_max_file"
chmod 0444 "$backlight_max_file"
if lock_error=$("$helper" status 2>&1); then
    printf '%s\n' 'contended device lock was accepted' >&2
    exit 1
fi
[ "$lock_error" = 'emacsos-openrc-device: device control is busy' ]
chmod 0644 "$backlight_max_file"
printf '%s\n' 3124 >"$backlight_max_file"
chmod 0444 "$backlight_max_file"
flock -u 8

grep -F 'exec /usr/bin/timeout -s TERM -k 1 5 "$helper" --worker "$@"' \
    "$source" >/dev/null
grep -F 'backlight_max=3124' "$source" >/dev/null
grep -F 'root_owner=root' "$source" >/dev/null
grep -F 'root_group=root' "$source" >/dev/null
grep -F 'device_dir_mode=755' "$source" >/dev/null
grep -F 'device_dir_links=3' "$source" >/dev/null
grep -F 'backlight_dir=/sys/devices/platform/backlight/backlight/backlight' \
    "$source" >/dev/null
grep -F 'backlight_brightness_mode=644' "$source" >/dev/null
grep -F 'backlight_max_mode=444' "$source" >/dev/null
grep -F 'backlight_25=781' "$source" >/dev/null
grep -F 'backlight_50=1562' "$source" >/dev/null
grep -F 'backlight_75=2343' "$source" >/dev/null
grep -F 'backlight_100=3124' "$source" >/dev/null
grep -F 'torch_brightness_group=feedbackd' "$source" >/dev/null
grep -F 'torch_dir=/sys/devices/platform/led-controller/leds/white:flash' \
    "$source" >/dev/null
grep -F 'torch_brightness_mode=664' "$source" >/dev/null
grep -F 'torch_max_mode=444' "$source" >/dev/null
grep -F 'torch_max=1' "$source" >/dev/null
grep -F 'torch_on=1' "$source" >/dev/null
grep -F 'torch_driver=/sys/bus/platform/drivers/sgm3140' "$source" >/dev/null
if grep -E '@[A-Z_]+@' "$source" >/dev/null; then
    printf '%s\n' 'device helper contains unresolved production markers' >&2
    exit 1
fi
if grep -F '/sys/class/' "$source" >/dev/null ||
   grep -E 'find .*sys|for .* in /sys/|gpio|strobe|flash-max-timeout' \
       "$source" >/dev/null; then
    printf '%s\n' 'device helper contains runtime sysfs discovery' >&2
    exit 1
fi

printf '%s\n' 'OpenRC device helper fixtures: OK'
