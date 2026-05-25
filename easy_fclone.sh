#!/usr/bin/env bash

# Name: easy_fclone.sh
# Description: Tool for easy creation of segmented forensic disk images
# Version 0.0.1-alpha: basic code writed
# Version 0.2.0-alpha: Refactored code
# Version 0.3.5-beta: Bug fixes, code improvements and visual
# Version 0.4.0-beta: Bug fixes, performance improvements, code cleanup
# Version 0.5.0-beta: Single-pass I/O, robustness improvements
# Version 0.6.0-beta: Restore mode, header validation, segment reconstruction
# Author: Erik Castro
# License: MIT
#

set -euo pipefail

show_help() {
    echo "Modo clone: $0 -s <device> -d <dir> -S <size> -B <size> -n <name> [-N <notes>]"
    echo "Modo restore: $0 -r -s <seg_dir> -d <output_file>"
    echo
    echo "Modo clone:"
    echo "  -s <source>           Dispositivo ou arquivo de origem."
    echo "  -d <destination_dir>  Diretório para armazenar os segmentos."
    echo "  -S <segment_size>     Tamanho de cada segmento (ex.: 1G, 512M)."
    echo "  -B <buffer_size>      Tamanho do buffer para dd (ex.: 32M, 64K)."
    echo "  -n <name_of_file>     Prefixo dos arquivos de segmento."
    echo "  -N <notes>            Notas para o cabeçalho."
    echo
    echo "Modo restore:"
    echo "  -r                    Modo restore (restaurar imagem a partir dos segmentos)."
    echo "  -s <seg_dir>          Diretório com os segmentos .bin."
    echo "  -d <output_file>      Arquivo de saída da imagem restaurada."
    echo
    echo "Exemplos:"
    echo "  $0 -s /dev/sda -d /backups -S 1G -B 32M -n case -N Case123"
    echo "  $0 -r -s /backups -d /imagem_restaurada.img"
    exit 0
}

IMAGE_NAME="image_$(date +"%Y%m%dT%H%M%S%z")"
BUFFER_SIZE="32M"
SEGMENT_SIZE="1G"
SOURCE=""
DEST_DIR=""
HEADER_NOTES=""
RESTORE_MODE=""
VOL_HASH_FILE="/tmp/vol_hash.$$"

while getopts ":rs:d:n:S:B:hN:" opt; do
    case $opt in
    r) RESTORE_MODE=1 ;;
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

# Lê e valida o cabeçalho de um segmento. Imprime pipe-delimited:
# data_start|hash_segment|hash_volume|segment_number|is_last|offset
parse_header() {
    local seg_file="$1"
    local file_size=$(stat -c%s "$seg_file")
    local seg_hash seg_num is_last data_start data_size hash_volume seg_offset

    local tail_size=2048
    [[ tail_size -gt file_size ]] && tail_size=$file_size
    local tail_offset=$((file_size - tail_size))

    local model_info
    model_info=$(dd if="$seg_file" bs=1 skip="$tail_offset" count="$tail_size" 2>/dev/null | grep -a -b -o -P '\|MODEL:' 2>/dev/null | tail -1)
    if [[ -z "$model_info" ]]; then
        msg_error "Cabeçalho inválido em '$seg_file': marcador MODEL ausente."
        return 1
    fi
    local model_rel_pos="${model_info%%:*}"
    data_start=$((tail_offset + model_rel_pos))
    data_size=$data_start

    local hash_info
    hash_info=$(dd if="$seg_file" bs=1 skip="$tail_offset" count="$tail_size" 2>/dev/null | grep -a -b -o -P '\|HEADER_HASH:[a-f0-9]+' 2>/dev/null | tail -1)
    if [[ -z "$hash_info" ]]; then
        msg_error "Cabeçalho inválido em '$seg_file': marcador HEADER_HASH ausente."
        return 1
    fi
    local hash_value="${hash_info##*:}"

    local header_text
    header_text=$(dd if="$seg_file" bs=1 skip="$data_start" count=$((file_size - data_start)) 2>/dev/null | tr -d '\0')

    local header_without_hash="${header_text%|HEADER_HASH:*}"
    local expected_hash
    expected_hash=$(echo -n "$header_without_hash" | get_hash | awk '{print $1}')
    if [[ "$expected_hash" != "$hash_value" ]]; then
        msg_error "HEADER_HASH inválido em '$seg_file'. Arquivo corrompido."
        return 1
    fi

    local fields="${header_without_hash#|}"
    local entry key value
    while IFS='|' read -ra entries; do
        for entry in "${entries[@]}"; do
            key="${entry%%:*}"
            value="${entry#*:}"
            case "$key" in
                HASH_SEGMENT) seg_hash="$value" ;;
                SEGMENT_NUMBER) seg_num="$value" ;;
                IS_LAST) is_last="$value" ;;
                HASH_VOLUME) hash_volume="$value" ;;
                OFFSET) seg_offset="$value" ;;
            esac
        done
    done <<< "$fields"

    if [[ -z "$seg_hash" || -z "$seg_num" || -z "$is_last" ]]; then
        msg_error "Campos obrigatórios ausentes no cabeçalho de '$seg_file'."
        return 1
    fi

    echo "$data_start|$seg_hash|$hash_volume|$seg_num|$is_last|$seg_offset"
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

restore_segments() {
    local seg_dir="$1"
    local output_file="$2"

    if [[ ! -d "$seg_dir" ]]; then
        msg_error "Diretório de segmentos '$seg_dir' não encontrado."
        exit 1
    fi

    if [[ -e "$output_file" ]]; then
        msg_error "Arquivo de saída '$output_file' já existe. Remova-o primeiro."
        exit 1
    fi

    local seg_files=("$seg_dir"/*.bin)
    if [[ ${#seg_files[@]} -eq 0 ]]; then
        msg_error "Nenhum arquivo .bin encontrado em '$seg_dir'."
        exit 1
    fi

    local sorted=()
    for f in "${seg_files[@]}"; do
        local base=$(basename "$f")
        local num=$(echo "$base" | grep -oP '\d{5,}(?=\.bin$)')
        if [[ -z "$num" ]]; then
            msg_error "Nome de arquivo inválido: '$base'. Esperado: <prefixo>_NNNNN.bin"
            exit 1
        fi
        sorted+=("$((10#$num))|$f")
    done
    IFS=$'\n' sorted=($(sort -t'|' -k1 -n <<< "${sorted[*]}")); unset IFS

    local seg_count=${#sorted[@]}
    local term_width
    term_width=$(tput cols)

    local volume_hash=""
    local expected_num=1
    local errors=0

    for entry in "${sorted[@]}"; do
        local file="${entry#*|}"
        local base=$(basename "$file")

        local header_data
        header_data=$(parse_header "$file") || { ((errors++)); continue; }
        local data_start seg_hash seg_hash_vol seg_num seg_is_last seg_offset
        IFS='|' read -r data_start seg_hash seg_hash_vol seg_num seg_is_last seg_offset <<< "$header_data"

        if [[ -z "$volume_hash" && -n "$seg_hash_vol" ]]; then
            volume_hash="$seg_hash_vol"
        fi

        local file_num=$((10#$(echo "$base" | grep -oP '\d{5,}(?=\.bin$)')))
        if ((file_num != seg_num)); then
            msg_error "$base: número do arquivo ($file_num) difere do cabeçalho ($seg_num)."
            ((errors++))
            continue
        fi
        if ((seg_num != expected_num)); then
            msg_error "Segmento $seg_num fora de ordem. Esperado: $expected_num."
            ((errors++))
            continue
        fi
        expected_num=$((seg_num + 1))

        progress_bar $((seg_num - 1)) $seg_count "Validando $base" $term_width

        local computed_hash
        computed_hash=$(dd if="$file" bs=64K iflag=count_bytes count="$data_start" status=none 2>/dev/null | tee -a "$output_file" | openssl dgst -sha3-256 | awk '{print $2}')

        if [[ "$computed_hash" != "$seg_hash" ]]; then
            msg_error "$base: hash do segmento não confere (dados corrompidos)."
            rm -f "$output_file"
            exit 1
        fi
    done

    if ((errors > 0)); then
        msg_error "$errors segmentos com erro. Restauração abortada."
        rm -f "$output_file"
        exit 1
    fi

    progress_bar $seg_count $seg_count "Verificando hash final..." $term_width

    if [[ -z "$volume_hash" ]]; then
        msg_error "HASH_VOLUME não encontrado em nenhum segmento."
        rm -f "$output_file"
        exit 1
    fi

    local final_hash
    final_hash=$(openssl dgst -sha3-256 "$output_file" 2>/dev/null | awk '{print $2}')
    if [[ "$final_hash" != "$volume_hash" ]]; then
        msg_error "Hash do arquivo restaurado difere do HASH_VOLUME original."
        rm -f "$output_file"
        exit 1
    fi

    echo -e "\n\t\e[1mA restauração foi realizada com sucesso!\e[0m"
}

if [[ -n "$RESTORE_MODE" ]]; then
    if [[ -z "$SOURCE" || -z "$DEST_DIR" ]]; then
        echo "Erro: Modo restore requer -s (diretório de segmentos) e -d (arquivo de saída)." >&2
        show_help
    fi
    restore_segments "$SOURCE" "$DEST_DIR"
else
    all_params_is_valid $SEGMENT_SIZE $BUFFER_SIZE
    echo -e "\e[1;33m\tEste software está em desenvolvimento, talvez apresente bugs e falhas.\n\tVocê é totalmente responsável pelo uso e como usa este software.\e[0m\n"
    create_segments "$SOURCE" "$DEST_DIR" "$SEGMENT_SIZE" "$BUFFER_SIZE"
fi
