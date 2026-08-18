#!/system/bin/sh

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
[ -n "$SCRIPT_DIR" ] || SCRIPT_DIR="$(pwd)"
cd "$SCRIPT_DIR" || exit 1

TARGET="/dev/block/by-name/dtbo"
LIST="./.dtbo-candidates.$$"
trap 'rm -f "$LIST"' EXIT INT TERM

printf '%s\n' '=========================================='
printf '%s\n' ' PCHM30 DTBO Flasher - MT Manager Terminal'
printf '%s\n' '=========================================='
printf '\n'

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "[ERROR] Root shell is required."
    echo "Open MT Manager terminal, run: su"
    echo "Then execute this script again."
    exit 1
fi

if [ ! -e "$TARGET" ]; then
    echo "[ERROR] DTBO partition not found: $TARGET"
    exit 1
fi

: > "$LIST"
for f in ./*.img ./*.IMG; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    lower="$(printf '%s' "$name" | tr 'A-Z' 'a-z')"
    case "$lower" in
        *dtbo*.img) printf '%s\n' "$f" >> "$LIST" ;;
    esac
done

COUNT="$(wc -l < "$LIST" | tr -d ' ')"
if [ -z "$COUNT" ] || [ "$COUNT" -eq 0 ]; then
    echo "[ERROR] No DTBO .img file was found beside this script."
    echo "Put this .sh and the DTBO .img file in the same folder."
    exit 1
fi

echo "DTBO images found in:"
echo "$SCRIPT_DIR"
echo
nl -w2 -s') ' "$LIST"
echo
printf 'Select the image number to flash: '
read PICK

case "$PICK" in
    ''|*[!0-9]*)
        echo "[ERROR] Invalid selection."
        exit 1
        ;;
esac

SELECTED="$(sed -n "${PICK}p" "$LIST")"
if [ -z "$SELECTED" ] || [ ! -f "$SELECTED" ]; then
    echo "[ERROR] Invalid selection."
    exit 1
fi

echo
echo "Selected: $SELECTED"
echo "Target  : $TARGET"
echo

echo "[1/3] Backing up current DTBO..."
BACKUP="./PCHM30-dtbo-backup-before-flash.img"
dd if="$TARGET" of="$BACKUP" bs=4M || {
    echo "[ERROR] Backup failed. Nothing was flashed."
    exit 1
}
sync

echo "Backup saved as:"
echo "$SCRIPT_DIR/${BACKUP#./}"
echo
printf 'Type yes to flash %s : ' "${SELECTED#./}"
read CONFIRM

if [ "$CONFIRM" != "yes" ] && [ "$CONFIRM" != "YES" ]; then
    echo "Cancelled. Nothing was flashed."
    exit 0
fi

echo
echo "[2/3] Flashing DTBO..."
dd if="$SELECTED" of="$TARGET" bs=4M || {
    echo "[ERROR] DTBO write failed."
    echo "Do NOT reboot until the backup is restored."
    exit 1
}
sync

echo
echo "[3/3] Flash completed successfully."
echo "Rebooting device..."
reboot
