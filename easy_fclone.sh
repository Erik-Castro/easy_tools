#!/usr/bin/env bash

# Name: easy_fclone.sh
# Description: Tool for easy creation of segmented forensic disk images
# Version 0.0.1-alpha: basic code writed
# Version 0.2.0-alpha: Refactored code
# Version 0.3.5-beta: Bug fixes, code improvements and visual
# Author: Erik Castro
# License: MIT
#

set -euo pipefail

show_help() {
    echo "Usage: $0 -s <source> -d <destination_dir> -S <segment_size> -B <buffer_size> -n <name_of_file>" echo
    echo "Arguments:" echo "  -s <source>           Source device or file to clone (e.g., /dev/sda)." echo "  -d <destination_dir>  Directory to store the output segments."
    echo "  -S <segment_size>     Size of each segment (e.g., 1G, 512M)." echo "  -B <buffer_size>      Buffer size for dd operations (e.g., 32M, 64K)."
    echo "  -n <name_of_file>     Name prefix for the output segments." echo "  -N <notes>            insert Notes in to header"
    echo
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
        echo "Erro a opção: -$OPTARG requer um argumento" >2
        show_help
        ;;
    esac
done

msg_error() {
    echo -e "\e[1;41m[ERRO]:\e[0;1m ${*} - $(date +%c)\e[0m" >&2
}

get_version() {
    # Verifica se o script é legível
    if [[ ! -r $0 ]]; then
        echo "Erro: Não foi possível ler o arquivo do script." >&2
        exit 1
    fi

    # Extrai a versão do script
    local version_line
    version_line=$(grep "^# Version " "$0" | tail -1)

    # Verifica se a linha de versão foi encontrada
    if [[ -z "$version_line" ]]; then
        echo "Aviso: A versão do script não foi encontrada." >&2
        return 1
    fi

    # Extrai e formata a versão
    local version
    version=$(echo "$version_line" | tr -d '\#' | cut -d':' -f1)

    # Exibe a versão
    echo $version
}

# Funcão para validar parametros
all_params_is_valid() {
    local segment=$1
    local buffer=$2
    local segment_size_bytes
    local buffer_size_bytes

    # Valida parametros obrigatórios
    if [[ -z $DEST_DIR ]]; then
        echo "Error:"
        show_help
        exit 1
    fi

    # Valida parametros obrigatórios
    if [[ -z $SOURCE ]]; then
        echo "Error:"
        show_help
        exit 1
    fi

    # Valida a origem dos dados
    if [[ ! -b $SOURCE && ! -f $SOURCE ]]; then
        msg_error "A origem '$SOURCE' não é um dispositivo ou arquivo válido."
        exit 1
    fi

    # Valida a entrada do segmento
    if ! [[ $segment =~ ^[0-9]+[KMGTPY]?$ ]]; then
        msg_error "O tamanho de segmento nao é valido. ex: 1M, 64K, 1G"
        exit 1
    fi

    # Valida a entrada do buffer
    if ! [[ $buffer =~ ^[0-9]+[KMGTPY]?$ ]]; then
        msg_error "O tamanho de segmento nao é valido. ex: 1M, 64K, 1G"
        exit 1
    fi

    # Converte as string para bytes
    buffer_size_bytes=$(numfmt --from=auto $BUFFER_SIZE)
    segment_size_bytes=$(numfmt --from=auto $SEGMENT_SIZE)

    if ((buffer_size_bytes < 512)); then
        msg_error "O tamanho do buffer é muito pequeno. Escolha algo maior que 512B."
        exit4
    fi

    # Valida tamanhos de buffer e segmento
    if ((segment_size_bytes < buffer_size_bytes)); then
        msg_error "O tamanho do segmento deve ser maior ou igual a o tamanho ''buffer'"
        exit 3
    fi
}

get_uuid() {
    # Variável responsável por armazenar o UUID
    local uuid

    # Verifica dependência
    if command -v uuidgen &>/dev/null; then
        uuid=$(uuidgen)
    elif command -v dbus-uuidgen &>/dev/null; then
        uuid=$(dbus-uuidgen)
    else
        msg_error "Este script precisa de \"uuidgen\" ou \"dbus-uuidgen\". Por favor, instale um deles."
        return 2
    fi

    # Verifica se o UUID foi gerado corretamente
    if [[ -z "$uuid" ]]; then
        msg_error "Falha ao gerar o UUID."
        return 3
    fi

    # Imprime o UUID gerado
    echo $uuid
    return 0
}

get_vol_info() {

    # Valida dependências
    if ! command -v lsblk &>/dev/null; then
        msg_error "'lsblk' é nescessario para extrair informações.\nTalvez prescise executar este script como root"
        exit 2
    fi

    # Valida dependências
    if ! command -v fdisk &>/dev/null; then
        msg_error "'fdisk' é nescessario para extrair informações.\nTalvez prescise executar este script como root"
        exit 2
    fi

    # Verifica se a variável SOURCE está definida
    if [[ -z "$SOURCE" ]]; then
        msg_error "A variável SOURCE não está definida. Por favor, defina o caminho do dispositivo."
        return 1
    fi

    # Verifica se o dispositivo existe
    if [[ ! -e "$SOURCE" ]]; then
        msg_error "O dispositivo '$SOURCE' não foi encontrado."
        return 2
    fi

    # Informações extraídas
    NAME_DEVICE=$(lsblk -d -o NAME "$SOURCE" 2>/dev/null | tail -1 || echo "unknown-name")
    SERIAL_DEVICE=$(lsblk -d -o SERIAL "$SOURCE" 2>/dev/null | tail -1 || echo "unknown-serial")
    DEVICE_MODEL=$(lsblk -d -o MODEL "$SOURCE" 2>/dev/null | tail -1 || echo "unknown-model")
    DEVICE_FSTYPE=$(lsblk -d -o FSTYPE "$SOURCE" 2>/dev/null | tail -1 || echo "unknown-fs")
    TOTAL_BYTES_VOL=$(fdisk -l "$SOURCE" 2>/dev/null | grep "$SOURCE" | awk '{print $5}' || echo "unknown-size")
    SECTOR_SIZE=$(fdisk -l "$SOURCE" | awk 'NR==4' | grep -oP "[0-9]+" | tail -1 || echo "unknown-sector-size")

    # Fallback para valores nulos
    NAME_DEVICE=${NAME_DEVICE:-"não_disponível"}
    SERIAL_DEVICE=${SERIAL_DEVICE:-"não_disponível"}
    DEVICE_MODEL=${DEVICE_MODEL:-"não_disponível"}
    DEVICE_FSTYPE=${DEVICE_FSTYPE:-"não_disponível"}
    TOTAL_BYTES_VOL=${TOTAL_BYTES_VOL:-"não_disponível"}
    SECTOR_SIZE=${SECTOR_SIZE:-"não_disponível"}

    return 0
}

# Gera o timestamp no padrão conforme regulamento
get_timesatamp() {
    echo $(date -u '+%Y-%m-%dT%H:%M:%SZ')
}

get_hash() {
    # Verifica se o OpenSSL está instalado
    if ! command -v openssl &>/dev/null; then
        echo "Erro: OpenSSL é necessário para calcular o hash." >&2
        exit 2
    fi

    # Define o algoritmo padrão
    local algorithm="sha3-256"

    # Valida se há argumento fornecido
    if [[ -z ${1+x} ]]; then
        # Calcula o hash da entrada padrão
        hash_output=$(openssl dgst -"$algorithm" 2>/dev/null)
        if [[ $? -ne 0 ]]; then
            echo "Erro: Falha ao calcular o hash com o algoritmo '$algorithm'." >&2
            exit 3
        fi
        echo -n "$hash_output" | awk '{print $2}'
    else
        # Verifica se o arquivo existe
        if [[ ! -f "$1" ]]; then
            echo "Erro: O arquivo '$1' não foi encontrado." >&2
            exit 4
        fi

        # Calcula o hash do arquivo
        hash_output=$(openssl dgst -"$algorithm" "$1" 2>/dev/null)
        if [[ $? -ne 0 ]]; then
            echo "Erro: Falha ao calcular o hash com o algoritmo '$algorithm'." >&2
            exit 3
        fi
        echo -n "$hash_output" | awk '{print $2}'
    fi
}

get_vol_hash() {
    # Verifica se a variável SOURCE está definida
    if [[ -z "$SOURCE" ]]; then
        msg_error "A variável SOURCE não está definida. Por favor, defina o caminho do volume."
        return 1
    fi

    # Verifica se o arquivo existe
    if [[ ! -e "$SOURCE" ]]; then
        msg_error "O arquivo ou volume '$SOURCE' não foi encontrado."
        return 2
    fi

    # Obtém o hash do volume
    local vol_hash
    vol_hash=$(dd if="$SOURCE" bs="64K" iflag=fullblock status=progress | get_hash | awk '{print $1}')

    # Verifica se o hash foi gerado corretamente
    if [[ -z "$vol_hash" ]]; then
        msg_error "Falha ao calcular o hash do volume."
        return 3
    fi

    # Imprime o hash do volume
    echo $vol_hash
    return 0
}

# gerando cabeçalho
write_head() {
    local header
    local hash_header

    header=$(
        cat <<EOF
|MODEL:$1|SERIAL:$2|DEVICE_NAME:$3|FSTYPE:${DEVICE_FSTYPE}|SECTOR_SIZE:${SECTOR_SIZE}|TOTAL_BYTES_VOLUME:${TOTAL_BYTES_VOL}|IMAGE_UUID:${10}|IMAGE_NAME:'"${IMAGE_NAME}"'|TIMESTAMP:$4|OFFSET:$5|SEGMENT_NUMBER:$6|SEGMENT_SIZE:$7|NOTES:'"${HEADER_NOTES}"'|HASH_SEGMENT:$8|HASH_VOLUME:$9|OPERATOR:$(whoami)|IS_LAST:${11}|HASH_ALGORITHM:SHA3-256|SCRIPT_VERSION:'"$(get_version)"'
EOF
    )
    hash_header=$(echo -n $header | get_hash | awk '{print $1}')

    echo -n "${header}|HEADER_HASH:${hash_header}"
}

get_calculated_count() {
    # Verifica se foram fornecidos dois argumentos
    if [[ $# -ne 2 ]]; then
        echo "Erro: Dois argumentos são necessários: <tamanho total> <tamanho do buffer>." >&2
        return 1
    fi

    local segment_size_bytes buffer_size_bytes count

    # Converte os argumentos para bytes
    segment_size_bytes=$(numfmt --from=auto "$1" 2>/dev/null)
    buffer_size_bytes=$(numfmt --from=auto "$2" 2>/dev/null)

    # Verifica se a conversão foi bem-sucedida
    if [[ -z "$segment_size_bytes" || -z "$buffer_size_bytes" ]]; then
        echo "Erro: Um ou ambos os argumentos são inválidos." >&2
        return 2
    fi

    # Verifica se o tamanho do buffer é maior que zero
    if ((buffer_size_bytes <= 0)); then
        echo "Erro: O tamanho do buffer deve ser maior que zero." >&2
        return 3
    fi

    # Calcula o número total de segmentos
    ((count = segment_size_bytes / buffer_size_bytes))
    [[ "$((segment_size_bytes % buffer_size_bytes))" -ne 0 ]] && ((count++))

    # Imprime o resultado
    echo $count
    return 0
}

progress_bar() {
    local progress=$1
    local progress_total=$2
    local msg="$3"
    local term_width percentage num_blocks bar_width bar color rst

    color=""
    rst="\e[0m"
    # Valida entrada
    if [[ ! $progress =~ [0-9]+ ]]; then
        msg_error "É preciso passar um valor inteiro para o primeiro parametro."
        exit 1
    fi

    # Idem
    if [[ ! $progress_total =~ [0-9]+ ]]; then
        msg_error "É presciso que o segundo paretro seja um inteiro"
        exit 1
    fi

    percentage=$(((progress * 100) / progress_total)) # Calcula o progresso
    term_width=$(tput cols)                           # Obtem a largura do terminal

    # Valida se a mensagem
    if [[ -z ${3+x} ]]; then
        bar_width=$term_width
    else
        bar_width=$((term_width - 27))
    fi

    # Calcula o numero de blocos para a barra
    num_blocks=$(((percentage * bar_width) / 100))

    # Preenche a varialvel que sera a representação visual
    for ((i = 0; i < bar_width; i++)); do

        if ((i < num_blocks)); then
            if ((percentage <= 49)); then
                color="\e[1;31m"
            elif ((percentage >= 50 && percentage <= 80)); then
                color="\e[1;33m"
            elif ((percentage >= 80)); then
                color="\e[1;32m"
            fi

            bar+="${color}#${rst}"

        elif ((i == num_blocks)); then
            bar+="\e[1;33m|\e[0m"
        else
            bar+=" "
        fi
    done

    # Sanitização básica de string
    msg=$(echo $msg | tr -cd '[:alnum:][:space:][:punct:]')

    # Imprime na saida padrao a representação do progresso
    printf "\r%03d%% [%b] %.19s" $percentage "$bar" "$msg"

    # Imprime uma nova linha quando atingir 100 para evitar glitches visuais
    if ((percentage == 100)); then
        echo
    fi
}

create_segments() {
    local SRC="$1"
    local dest_dir="$2"
    local segment_size="$3"
    local buffer_size="$4"
    local uuid="$(get_uuid)"
    local total_size segment_count segment_num=1 is_last=0 offset=0
    local segment_file segment_hash timestamp volume_hash

    total_size="${TOTAL_BYTES_VOL}" # Tamanho total do volume em bytes

    echo -e "\e[1;32m\tCalculando a hash do volume.\tEste é um processo demorado, que vai depender de suas configurações de hardware.\n\e[0m"
    volume_hash="$(get_vol_hash)"                                          # Calcula hash do volume original
    segment_count="$(get_calculated_count "$segment_size" "$buffer_size")" # Blocos por segmento

    # Verifica de o destino existe
    if [[ ! -d "$dest_dir" ]]; then
        mkdir -p "$dest_dir" # Garante a existê do diretório
    fi

    while ((offset < total_size)); do
        segment_file="$dest_dir/${IMAGE_NAME}$(printf "%05d" "$segment_num").bin"
        segment_size="$(numfmt --from=auto "$segment_size")"
        if ((offset + segment_size > total_size)); then
            segment_size=$((total_size - offset))
            is_last=1
        fi

        local required_space=$(numfmt --from=auto "$SEGMENT_SIZE")
        local avaliable_space=$(df --output=avail "$DEST_DIR" | tail -1)

        if ((required_space > avaliable_space * 1024)); then
            msg_error "Epaço insuficiente em '$DEST_DIR'. Nescessário: '$SEGMENT_SIZE'"
            exit 7
        fi

        buffer_size="$(numfmt --from=auto "$buffer_size")"
        progress_bar $offset $total_size "Criando segmento ${segment_file}"
        dd if="$SRC" of="$segment_file" iflag=fullblock conv=sync status=none bs="$buffer_size" skip=$((offset / buffer_size)) count="$segment_count"
        if [[ $? -ne 0 ]]; then
            msg_error "Falha ao executar o comando dd. Verifique as permissões ou o destino."
            exit 6
        fi

        # Calcular o hash do segmento
        segment_hash="$(get_hash "$segment_file")"
        timestamp="$(get_timesatamp)" # Obtém o timestam
        progress_bar $offset $total_size "Calculando o hash do segemento ${segment_file}"

        # Escreve o cabeçalho
        write_head "${DEVICE_MODEL}" "${SERIAL_DEVICE}" "${NAME_DEVICE}" "$timestamp" "$offset" "$segment_num" "$(wc -c "$segment_file" | cut -d ' ' -f1)" "$segment_hash" "$volume_hash" "$uuid" "$is_last" >>"$segment_file"

        progress_bar $offset $total_size "Cabeçalho do segmento: ${segment_file} criado!"

        ((offset += segment_size))
        ((segment_num++))
        progress_bar $offset $total_size "Segmento criado com sucesso!"
    done
    echo -e "\t\e[1mA clonagem foi realizada com sucesso!\e[0m"
}

all_params_is_valid $SEGMENT_SIZE $BUFFER_SIZE
echo -e "\e[1;33m\tEste software está em desenvolvimento, talvez apresente bugs e falhas.\n\tVocê é totalmente responsável pelo uso e como usa este software.\e[0m\n"
get_vol_info
create_segments "$SOURCE" "$DEST_DIR" "$SEGMENT_SIZE" "$BUFFER_SIZE"
