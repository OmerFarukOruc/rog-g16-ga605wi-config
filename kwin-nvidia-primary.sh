#!/bin/bash
# Make KWin composite on the NVIDIA dGPU (persistent, Hybrid mode).
#
# Writes KWIN_DRM_DEVICES=<nvidia>:<amd> (NVIDIA = compositor primary) into
# environment.d for every real user + the plasmalogin greeter, before the display
# manager starts. Cards are resolved by PCI vendor ID at boot because /dev/dri/cardN
# renumbers between boots and KWIN_DRM_DEVICES cannot use /dev/dri/by-path (its ':'
# list separator collides with the colons inside PCI by-path names).
#
# Trade-off: NVIDIA composites everything, so the dGPU never RTD3-sleeps. That keeps the
# desktop (and any external/dock display on the dGPU) smooth, at the cost of a few extra
# watts. On battery with no external display this is wasteful and adds a reverse iGPU
# copy for the internal panel — see README for the "only when an external display is
# attached" variant if you want battery friendliness when mobile.

set -u

NVIDIA_CARD=""
AMD_CARD=""
for card in /sys/class/drm/card[0-9]; do
    [ -e "$card" ] || continue
    vendor=$(cat "$card/device/vendor" 2>/dev/null) || continue
    name=$(basename "$card")
    case $vendor in
        0x10de) NVIDIA_CARD="/dev/dri/$name" ;;
        0x1002) AMD_CARD="/dev/dri/$name" ;;
    esac
done

if [ -z "$NVIDIA_CARD" ] || [ -z "$AMD_CARD" ]; then
    echo "kwin-nvidia-primary: NVIDIA or AMD card not found (nv=$NVIDIA_CARD amd=$AMD_CARD), skipping"
    exit 0
fi
echo "kwin-nvidia-primary: NVIDIA=$NVIDIA_CARD (primary) AMD=$AMD_CARD"

write_env() {
    local home="$1" user="$2"
    local dir="$home/.config/environment.d"
    local file="$dir/kwin-drm.conf"
    local group
    group=$(id -gn "$user" 2>/dev/null || printf '%s' "$user")
    mkdir -p "$dir"
    printf 'KWIN_DRM_DEVICES=%s:%s\nKWIN_DRM_ALLOW_NVIDIA_COLORSPACE=1\n' "$NVIDIA_CARD" "$AMD_CARD" > "$file"
    chown "$user:$group" "$dir" "$file" 2>/dev/null
    echo "kwin-nvidia-primary: wrote $file for $user"
}

for home in /home/*; do
    [ -d "$home" ] || continue
    user=$(basename "$home")
    uid=$(id -u "$user" 2>/dev/null) || continue
    [ "$uid" -ge 1000 ] || continue
    write_env "$home" "$user"
done

greeter_home=$(getent passwd plasmalogin 2>/dev/null | cut -d: -f6)
[ -n "$greeter_home" ] && write_env "$greeter_home" plasmalogin

echo "kwin-nvidia-primary: done"
