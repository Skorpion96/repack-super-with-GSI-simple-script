#!/bin/bash
set -e

### Dependency check ###
for cmd in simg2img lz4 lpunpack lpdump gzip unrar 7z bunzip2 tar unzip gunzip; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Missing dependency: $cmd"
        exit 1
    fi
done

read -rp "Enter working path: " WORK_PATH
cd $WORK_PATH

    read -rp "Enter path to gsi: " GSI_IMG
    if [[ -f $GSI_IMG ]]; then
        # Check if file is compressed
        case "$GSI_IMG" in
            *.gz)
                echo "Detected gzip compressed file, extracting..."
                EXTRACTED="${GSI_IMG%.gz}"
                gunzip -c "$GSI_IMG" > "$EXTRACTED"
                GSI="$EXTRACTED"
                ;;
            *.zip)
                echo "Detected zip file, extracting..."
                EXTRACTED="${GSI_IMG%.zip}"
                unzip -p "$GSI_IMG" > "$EXTRACTED"
                GSI="$EXTRACTED"
                ;;
            *.tar.gz|*.tgz)
                echo "Detected tar.gz file, extracting..."
                EXTRACTED="${GSI_IMG%.tar.gz}"
                tar -xzOf "$GSI_IMG" > "$EXTRACTED"
                GSI="$EXTRACTED"
                ;;
            *.bz2)
                echo "Detected bzip2 compressed file, extracting..."
                EXTRACTED="${GSI_IMG%.bz2}"
                bunzip2 -c "$GSI_IMG" > "$EXTRACTED"
                GSI="$EXTRACTED"
                ;;
            *.7z)
                echo "Detected 7z compressed file, extracting..."
                EXTRACTED="${GSI_IMG%.7z}"
                7z e "$GSI_IMG" -so > "$EXTRACTED" 2>/dev/null
                GSI="$EXTRACTED"
                ;;
            *.tar.xz)
                echo "Detected tar.xz compressed file, extracting..."
                N_ENTRIES=$(tar -tf "$GSI_IMG" | wc -l)
               if (( N_ENTRIES != 1 )); then
               echo "tar.xz contains $N_ENTRIES entries, expected exactly 1"
               exit 1
               fi
               EXTRACTED="${GSI_IMG%.tar.xz}"
               tar -xJOf "$GSI_IMG" > "$EXTRACTED"
               GSI="$EXTRACTED"
               ;;
            *.xz)
               echo "Detected xz compressed file, extracting..."
               EXTRACTED="${GSI_IMG%.xz}"
               xz -dc "$GSI_IMG" > "$EXTRACTED"
               GSI="$EXTRACTED"
               ;;
               *)
               GSI="$GSI_IMG"
               ;;
        esac
    else
        echo "Something went wrong, exiting"
        exit 1
    fi

    read -rp "Enter path to super (in img/bin format): " SUPER_IMG
    if [[ -f $SUPER_IMG ]]; then
    MAGIC=$(head -c4 "$SUPER_IMG" | xxd -p)
    if [[ "$MAGIC" == "3aff26ed" ]]; then
    echo "Android sparse image detected, converting..."
    simg2img "$SUPER_IMG" "$SUPER_IMG.raw"
    SUPER_IMG="$SUPER_IMG.raw"
    fi
    mkdir unpack_tmp
    echo "extracting subpartitions from super"
    lpunpack $SUPER_IMG unpack_tmp    
    fi

LPDUMP_OUT=$(lpdump "$SUPER_IMG" 2>/dev/null || true)

GROUP_NAME=$(echo "$LPDUMP_OUT" | sed -n '/^Partition table:/,/^Super partition layout:/p' \
    | grep "  Group:" | grep -v "cow$" | head -1 | awk '{print $2}')
GROUP_NAME="${GROUP_NAME:-main}"
echo "Using group name: $GROUP_NAME"

#### Detect slot suffix ####
SLOT_SUFFIX=""
if ls unpack_tmp/*_a.img &>/dev/null; then
    SLOT_SUFFIX="_a"
elif ls unpack_tmp/*_b.img &>/dev/null; then
    SLOT_SUFFIX="_b"
fi
echo "Slot suffix: '${SLOT_SUFFIX:-none}'"

#### Swap the GSI into system ####
SYSTEM_IMG="unpack_tmp/system${SLOT_SUFFIX}.img"
[[ -f $SYSTEM_IMG ]] || { echo "No system${SLOT_SUFFIX}.img in unpack_tmp"; exit 1; }
cp "$GSI" "$SYSTEM_IMG"

#### Build partition/image args, skip cow/scratch, align sizes ####
declare -a PART_ARGS IMAGE_ARGS
TOTAL_SIZE=0
BLOCK_ALIGN=4096

for img in unpack_tmp/*.img; do
    name=$(basename "$img" .img)
    case "$name" in
        *cow*|*scratch*)
            echo "Skipping $name (not a flashable partition)"
            continue
            ;;
    esac
    size=$(stat -c%s "$img")
    aligned=$(( (size + BLOCK_ALIGN - 1) / BLOCK_ALIGN * BLOCK_ALIGN ))
    PART_ARGS+=(--partition "${name}:readonly:${aligned}:${GROUP_NAME}")
    IMAGE_ARGS+=(--image "${name}=./${img}")
    TOTAL_SIZE=$((TOTAL_SIZE + aligned))
done

#### Compute group/device size from what we're actually building ####
METADATA_SIZE=65536
METADATA_SLOTS=3
GROUP_SLACK=$((16 * 1024 * 1024))   # headroom inside the group for lpmake's own alignment/extent overhead
DEVICE_SLACK=$((4 * 1024 * 1024))   # headroom for the device itself beyond metadata

GROUP_MAX=$((TOTAL_SIZE + GROUP_SLACK))
DEVICE_SIZE=$(( GROUP_MAX + METADATA_SIZE * METADATA_SLOTS + DEVICE_SLACK ))
echo "Sum of partitions: $TOTAL_SIZE -> group max: $GROUP_MAX, device size: $DEVICE_SIZE"
echo "Note: this is sized to fit what we're building, NOT the original device's super capacity."
echo "If GROUP_MAX exceeds your device's real super partition, flashing will fail - that's expected, just try a smaller GSI."

lpmake --metadata-size "$METADATA_SIZE" \
    --super-name super \
    --metadata-slots "$METADATA_SLOTS" \
    --device "super:${DEVICE_SIZE}" \
    --group "${GROUP_NAME}:${GROUP_MAX}" \
    "${PART_ARGS[@]}" \
    "${IMAGE_ARGS[@]}" \
    --sparse \
    --output ./super_new.img

#### Cleanup ####
CLEANUP_FILES=()
[[ -n "${EXTRACTED:-}" && -f "$EXTRACTED" ]] && CLEANUP_FILES+=("$EXTRACTED")
[[ -f "${SUPER_IMG}" ]] && CLEANUP_FILES+=("${SUPER_IMG}")
[[ -f "${GSI_IMG}" ]] && CLEANUP_FILES+=("${GSI_IMG}")

cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf unpack_tmp
    for f in "${CLEANUP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT
