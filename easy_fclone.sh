#!/usr/bin/env bash

# Name: easy_fclone.sh
# Description: Tool for easy creation of segmented forensic disk images
# Version 0.0.1-alpha: basic code writed
# Version 0.2.0-alpha: Refactored code
# Version 0.3.5-beta: Bug fixes, code improvements and visual
# Version 0.4.0-beta: Bug fixes, performance improvements, code cleanup
# Version 0.5.0-beta: Single-pass I/O, robustness improvements
# Author: Erik Castro
# License: MIT
#

set -euo pipefail

show_help() {
    echo "Usage: $0 -s <source> -d <destination_dir> -S <segment_size> -B <buffer_size> -n <name_of_file>"
    echo
    echo "Arguments:"
    echo "  -s <source>           Source device or file to clone (e.g., /dev/sda)."
    echo "  -d <destination_dir>  Directory to store the output segments."
    echo "  -S <segment_size>     Size of each segment (e.g., 1G, 512M)."
    echo "  -B <buffer_size>      Buffer size for dd operations (e.g., 32M, 64K)."
    echo "  -n <name_of_file>     Name prefix for the output segments."
    echo "  -N <notes>            Insert notes into the header."
    echo
    echo "Example:"
    echo "  $0 -s /dev/sda -d /backups -S 1G -B 32M -n segment_file -N CaseID123456-89"
    exit 0
}

IMAGE_NAME="image_$(date +"%Y%m%dT%H%M%S%z")"
BUFFER_SIZE="32M"
SEGMENT_SIZE="1G"
SOURCE=""
DEST_DIR=""
HEADER_NOTES=""
VOL_HASH_FILE="/tmp/vol_hash.$$"

while getopts ":s:d:n:S:B:hN:" opt; do
    case $opt in
    s) SOURCE="$OPTARG" ;;
    d) DEST_DIR="$OPTARG" ;;
    n) IMAGE_NAME="$OPTARG" ;;
    S) SEGMENT_SIZE="$OPTARG" ;;
    B) BUFFER_SIZE="$OPTARG" ;;
    h) show_help ;;
    N) HEADER_NOTES="${OPTARG}" ;;
    \?)
        echo "Erro: Opção inválida -$OPTARG" >&2
        show_help
        ;;
    :)
        echo "Erro: a opção -$OPTARG requer um argumento" >&2
        show_help
        ;;
    esac
done

msg_error() {
    echo -e "\e[1;41m[ERRO]:\e[0;1m ${*} - $(date +%c)\e[0m" >&2
}

# Garante limpeza mesmo em caso de interrupção
trap 'rm -f "$VOL_HASH_FILE" 2>/dev/null; exit 1' INT TERM
trap 'rm -f "$VOL_HASH_FILE" 2>/dev/null' EXIT

get_version() {
    if [[ ! -r $0 ]]; then
        echo "Erro: Não foi possível ler o arquivo do script." >&2
        exit 1
    fi

    local version_line
    version_line=$(grep "^# Version " "$0" | tail -1)

    if [[ -z "$version_line" ]]; then
        echo "Aviso: A versão do script não foi encontrada." >&2
        return 1
    fi

    local version
    version=$(echo "$version_line" | tr -d '\#' | cut -d':' -f1)

    echo $version
}

all_params_is_valid() {
    local segment=$1
    local buffer=$2
    local segment_size_bytes
    local buffer_size_bytes

    if [[ -z $DEST_DIR ]]; then
        echo "Error:"
        show_help
        exit 1
    fi

    if [[ -z $SOURCE ]]; then
        echo "Error:"
        show_help
        exit 1
    fi

    if [[ ! -b $SOURCE && ! -f $SOURCE ]]; then
        msg_error "A origem '$SOURCE' não é um dispositivo ou arquivo válido."
        exit 1
    fi

    if ! [[ $segment =~ ^[0-9]+[KMGTPY]?$ ]]; then
        msg_error "O tamanho de segmento não é válido. Ex: 1M, 64K, 1G"
        exit 1
    fi

    if ! [[ $buffer =~ ^[0-9]+[KMGTPY]?$ ]]; then
        msg_error "O tamanho de buffer não é válido. Ex: 1M, 64K, 1G"
        exit 1
    fi

    buffer_size_bytes=$(parse_size $BUFFER_SIZE)
    segment_size_bytes=$(parse_size $SEGMENT_SIZE)

    if ((buffer_size_bytes < 512)); then
        msg_error "O tamanho do buffer é muito pequeno. Escolha algo maior que 512B."
        exit 1
    fi

    if ((segment_size_bytes < buffer_size_bytes)); then
        msg_error "O tamanho do segmento deve ser maior ou igual ao tamanho do buffer."
        exit 3
    fi
}

get_uuid() {
    local uuid

    if command -v uuidgen &>/dev/null; then
        uuid=$(uuidgen)
    elif command -v dbus-uuidgen &>/dev/null; then
        uuid=$(dbus-uuidgen)
    else
        msg_error "Este script precisa de \"uuidgen\" ou \"dbus-uuidgen\". Por favor, instale um deles."
        return 2
    fi

    if [[ -z "$uuid" ]]; then
        msg_error "Falha ao gerar o UUID."
        return 3
    fi

    echo $uuid
    return 0
}

get_vol_info() {
    local src="$1"

    if ! command -v lsblk &>/dev/null; then
        msg_error "'lsblk' é necessário para extrair informações.\nTalvez precise executar este script como root."
        exit 2
    fi

    if ! command -v fdisk &>/dev/null; then
        msg_error "'fdisk' é necessário para extrair informações.\nTalvez precise executar este script como root."
        exit 2
    fi

    if [[ -z "$src" ]]; then
        msg_error "A variável SOURCE não está definida. Por favor, defina o caminho do dispositivo."
        return 1
    fi

    if [[ ! -e "$src" ]]; then
        msg_error "O dispositivo '$src' não foi encontrado."
        return 2
    fi

    local name serial model fstype total_bytes sector_size

    name=$(lsblk -d -o NAME "$src" 2>/dev/null | tail -1 || echo "não_disponível")
    serial=$(lsblk -d -o SERIAL "$src" 2>/dev/null | tail -1 || echo "não_disponível")
    model=$(lsblk -d -o MODEL "$src" 2>/dev/null | tail -1 || echo "não_disponível")
    fstype=$(lsblk -d -o FSTYPE "$src" 2>/dev/null | tail -1 || echo "não_disponível")
    total_bytes=$(fdisk -l "$src" 2>/dev/null | grep "$src" | awk '{print $5}' || echo "não_disponível")
    sector_size=$(fdisk -l "$src" 2>/dev/null | awk 'NR==4' | grep -oP "[0-9]+" | tail -1 || echo "não_disponível")

    echo "$name|$serial|$model|$fstype|$total_bytes|$sector_size"
}

get_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Converte tamanhos com sufixo para bytes (tratando K/M/G como binário, igual ao dd)
parse_size() {
    local input="$1"
    local num=${input%[KMGTPYkMmgttpy]}
    local suffix="${input: -1}"
    case "$suffix" in
        K|k) echo $((num * 1024)) ;;
        M|m) echo $((num * 1024 * 1024)) ;;
        G|g) echo $((num * 1024 * 1024 * 1024)) ;;
        T|t) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
        P|p) echo $((num * 1024 * 1024 * 1024 * 1024 * 1024)) ;;
        Y|y) echo $((num * 1024 * 1024 * 1024 * 1024 * 1024 * 1024)) ;;
        *) echo "$input" ;;
    esac
}

get_hash() {
    if ! command -v openssl &>/dev/null; then
        echo "Erro: OpenSSL é necessário para calcular o hash." >&2
        exit 2
    fi

    local algorithm="sha3-256"

    if [[ -z ${1+x} ]]; then
        openssl dgst -"$algorithm" 2>/dev/null | awk '{print $2}'
    else
        if [[ ! -f "$1" ]]; then
            echo "Erro: O arquivo '$1' não foi encontrado." >&2
            exit 4
        fi
        openssl dgst -"$algorithm" "$1" 2>/dev/null | awk '{print $2}'
    fi
}

write_head() {
    local header
    local hash_header

    header=$(
        cat <<EOF
|MODEL:$1|SERIAL:$2|DEVICE_NAME:$3|FSTYPE:${DEVICE_FSTYPE}|SECTOR_SIZE:${SECTOR_SIZE}|TOTAL_BYTES_VOLUME:${TOTAL_BYTES_VOL}|IMAGE_UUID:${10}|IMAGE_NAME:'"${IMAGE_NAME}"'|TIMESTAMP:$4|OFFSET:$5|SEGMENT_NUMBER:$6|SEGMENT_SIZE:$7|NOTES:'"${HEADER_NOTES}"'|HASH_SEGMENT:$8|HASH_VOLUME:$9|OPERATOR:$(whoami)|IS_LAST:${11}|HASH_ALGORITHM:SHA3-256|SCRIPT_VERSION:'"$(get_version)"'
EOF
    )
    hash_header=$(echo -n "$header" | get_hash | awk '{print $1}')

    echo -n "${header}|HEADER_HASH:${hash_header}"
}

progress_bar() {
    local progress=$1
    local progress_total=$2
    local msg="$3"
    local term_width="${4:-$(tput cols)}"
    local percentage num_blocks bar_width bar rst

    rst="\e[0m"

    if [[ ! $progress =~ [0-9]+ ]]; then
        msg_error "É preciso passar um valor inteiro para o primeiro parâmetro."
        exit 1
    fi

    if [[ ! $progress_total =~ [0-9]+ ]]; then
        msg_error "É preciso que o segundo parâmetro seja um inteiro."
        exit 1
    fi

    percentage=$(((progress * 100) / progress_total))

    if [[ -z ${3+x} ]]; then
        bar_width=$term_width
    else
        bar_width=$((term_width - 27))
    fi

    num_blocks=$(((percentage * bar_width) / 100))

    bar=""
    if ((num_blocks > 0)); then
        local fill
        fill=$(printf '#%.0s' $(seq 1 $num_blocks))
        if ((percentage <= 49)); then
            bar+="\e[1;31m${fill}\e[0m"
        elif ((percentage <= 80)); then
            bar+="\e[1;33m${fill}\e[0m"
        else
            bar+="\e[1;32m${fill}\e[0m"
        fi
    fi

    if ((num_blocks < bar_width)); then
        bar+="\e[1;33m|\e[0m"
        local remaining=$((bar_width - num_blocks - 1))
        if ((remaining > 0)); then
            bar+=$(printf ' %.0s' $(seq 1 $remaining))
        fi
    fi

    msg=$(echo "$msg" | tr -cd '[:alnum:][:space:][:punct:]')

    printf "\r%03d%% [%b] %.19s" $percentage "$bar" "$msg"

    if ((percentage == 100)); then
        echo
    fi
}

create_segments() {
    local SRC="$1"
    local dest_dir="$2"
    local segment_size="$3"
    local buffer_size="$4"
    local segment_num=1 offset=0
    local segment_file segment_hash timestamp volume_hash

    local vol_info
    vol_info="$(get_vol_info "$SRC")" || exit $?
    local NAME_DEVICE SERIAL_DEVICE DEVICE_MODEL DEVICE_FSTYPE TOTAL_BYTES_VOL SECTOR_SIZE
    IFS='|' read -r NAME_DEVICE SERIAL_DEVICE DEVICE_MODEL DEVICE_FSTYPE TOTAL_BYTES_VOL SECTOR_SIZE <<< "$vol_info"

    if [[ "$TOTAL_BYTES_VOL" == "não_disponível" ]] || ! [[ "$TOTAL_BYTES_VOL" =~ ^[0-9]+$ ]]; then
        msg_error "Não foi possível determinar o tamanho do volume."
        exit 1
    fi
    local total_size="$TOTAL_BYTES_VOL"

    local seg_size_bytes buf_size_bytes
    seg_size_bytes=$(parse_size "$segment_size")
    buf_size_bytes=$(parse_size "$buffer_size")

    if [[ ! -d "$dest_dir" ]]; then
        mkdir -p "$dest_dir" || {
            msg_error "Falha ao criar o diretório de destino '$dest_dir'."
            exit 1
        }
    fi

    local required_space=$(parse_size "$SEGMENT_SIZE")
    local available_space=$(df --output=avail "$DEST_DIR" | tail -1)
    if ((required_space > available_space * 1024)); then
        msg_error "Espaço insuficiente em '$DEST_DIR'. Necessário: '$SEGMENT_SIZE'."
        exit 7
    fi

    local term_width
    term_width=$(tput cols)

    local uuid
    uuid="$(get_uuid)" || exit $?

    echo -e "\e[1;32m\tCalculando a hash do volume em paralelo...\n\e[0m"
    ( openssl dgst -sha3-256 "$SRC" 2>/dev/null | awk '{print $2}' > "$VOL_HASH_FILE" ) &
    local vol_hash_pid=$!

    local -a seg_files
    local -a seg_hashes
    local -a seg_timestamps
    local -a seg_offsets

    while ((offset < total_size)); do
        segment_file="$dest_dir/${IMAGE_NAME}$(printf "%05d" "$segment_num").bin"

        local current_size=$seg_size_bytes
        if ((offset + current_size > total_size)); then
            current_size=$((total_size - offset))
        fi

        local current_count=$((current_size / buf_size_bytes))
        [[ $((current_size % buf_size_bytes)) -ne 0 ]] && ((++current_count))

        progress_bar $offset $total_size "Criando segmento ${segment_file}" $term_width
        dd if="$SRC" of="$segment_file" iflag=fullblock status=none bs="$buf_size_bytes" skip=$((offset / buf_size_bytes)) count="$current_count" || {
            msg_error "Falha ao executar o comando dd. Verifique as permissões ou o destino."
            exit 6
        }

        progress_bar $offset $total_size "Calculando o hash do segmento ${segment_file}" $term_width
        segment_hash="$(get_hash "$segment_file")"
        timestamp="$(get_timestamp)"

        seg_files+=("$segment_file")
        seg_hashes+=("$segment_hash")
        seg_timestamps+=("$timestamp")
        seg_offsets+=("$offset")

        progress_bar $offset $total_size "Segmento ${segment_file} concluído!" $term_width

        ((offset += current_size))
        ((segment_num++))
    done

    wait $vol_hash_pid 2>/dev/null || true
    if [[ -f "$VOL_HASH_FILE" ]]; then
        volume_hash=$(cat "$VOL_HASH_FILE")
    fi

    if [[ -z "$volume_hash" ]]; then
        msg_error "Falha ao calcular o hash do volume."
        exit 3
    fi

    progress_bar 100 100 "Anexando cabeçalhos..." $term_width
    local seg_count=${#seg_files[@]}
    for ((i = 0; i < seg_count; i++)); do
        local is_last=0
        ((i == seg_count - 1)) && is_last=1
        local seg_num=$((i + 1))
        local seg_size
        seg_size=$(wc -c < "${seg_files[i]}")

        progress_bar $i $seg_count "Cabeçalho do segmento ${seg_files[i]}" $term_width
        write_head "${DEVICE_MODEL}" "${SERIAL_DEVICE}" "${NAME_DEVICE}" "${seg_timestamps[i]}" "${seg_offsets[i]}" "$seg_num" "$seg_size" "${seg_hashes[i]}" "$volume_hash" "$uuid" "$is_last" >> "${seg_files[i]}"
    done
    progress_bar $seg_count $seg_count "Cabeçalhos concluídos!" $term_width

    echo -e "\n\t\e[1mA clonagem foi realizada com sucesso!\e[0m"
}

all_params_is_valid $SEGMENT_SIZE $BUFFER_SIZE
echo -e "\e[1;33m\tEste software está em desenvolvimento, talvez apresente bugs e falhas.\n\tVocê é totalmente responsável pelo uso e como usa este software.\e[0m\n"
create_segments "$SOURCE" "$DEST_DIR" "$SEGMENT_SIZE" "$BUFFER_SIZE"
