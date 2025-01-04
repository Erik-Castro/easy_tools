#!/usr/bin/env bash
#
# Name: easy_fsearch.sh
# Description: Tool for forensic searches of artifacts in a simple and easy way.
#
# Author: Erik Castro
# Version 0.0.1-alpha: Base code
# ================================================

set -euo pipefail

ERROR=()

# Chaves e variáveis de  configuração
DIRECTORY="."
REGEX=""
QUERY=""

# Temporários
TEMP_FILE[0]=$(mktemp -p. 2>/dev/null || (
    echo "Não foi possivel criar o arquivo temporário"
    exit 2
))

# Limpa arquivos temporaŕios
clean_temp() {
    for tmp in "${TEMP_FILE[@]}"; do
        echo "Removendo arquivo temporário: ${tmp}"
        [[ -e "${tmp}" ]] && (shred -uzn 33 "${tmp}")

        # Garantindo que removi :)
        [[ -e "${tmp}" ]] && rm -rf "${tmp}"
    done
}

trap "clean_temp" SIGTERM SIGINT SIGKILL SIGABRT SIGHUP EXIT

# Função para exibir mensagens de erro
msg_error() {
    local message="${1:-Algo inesperado aconteceu.}"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if [[ -t 1 ]]; then
        echo -e "\e[1;41m[ERRO]\e[0;1m: ${message}\t${timestamp}\e[0m" >&2
    else
        echo -e "[ERRO]: ${message}\t${timestamp}" >&2
    fi
}

# Função para registrar erros
error_registry() {
    if [[ -z "${1+x}" ]]; then
        msg_error "Erro inesperado!"
        exit 7
    fi
    ERROR+=("$1")
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

# Função para verificar dependências
check_dependencies() {
    local missing=()
    for cmd in updatedb locate find xargs openssl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        for cmd in "${missing[@]}"; do
            error_registry "A dependência \"$cmd\" é necessária, mas não foi encontrada."
        done
    fi
}

# Verificar parametrôs
directory_is_valid() {
    [[ -z "$DIRECTORY" ]] && (
        msg_error "O parâmetro '-d' é obrigatório, necessita de um pârametro."
        exit 3
    )

    [[ ! -d "$DIRECTORY" ]] && (
        msg_error "O parâmetro $DIRECTORY não é um diretório válido."
        exit 4
    )
    return 0
}

# Arquivos padrão
standard_files() {
    local standard_dir=("/home/*/.mozilla/firefox" "/tmp" "/var/tmp" "/home/*/.config/google-chrome/Default" "/var/log" "/etc" "/root" "/usr/local" "/opt" "/var/www" "/home/*/.ssh" "/home/*/.gnupg" "/var/backups")
    local line

    if [[ -t 1 ]]; then
        local arch="\e[1;34m"
        local dire="\e[1;35m"
        local bol="\e[1m"
        local res="\e[0m"
    else
        arch=""
        dire=""
        bol=""
    fi

    for dir in ${standard_dir[@]}; do
        # Se não houver, ignore
        [[ ! -d "$dir" ]] && continue

        # Realiza a busca no diretorio da vez
        find "${dir}" -maxdepth 5 >>${TEMP_FILE[0]}
    done

    while IFS= read -r line; do
        if [[ -f "$line" ]]; then
            echo -e "${arch}Arquivo encontrado:${res}${bol} ${line}"
        elif [[ -d "$line" ]]; then
            echo -e "${dire}Diretório encontrado:${res}${bol} ${line}${res}"
        else
            echo -e "${bol}Outro tipo encontrado: ${line}${res}"
        fi
    done <${TEMP_FILE[0]} | sort
}

# Buscar por logs
query_logs() {
    local line
    local temp_file="${TEMP_FILE[0]}" # Garantir compatibilidade com a variável TEMP_FILE

    # Verificar se o arquivo temporário existe
    if [[ ! -f "$temp_file" ]]; then
        msg_error "O arquivo temporário '${temp_file}' não foi encontrado!"
        return 1
    fi

    # Filtrar arquivos do diretório '/var/log/' e calcular seus hashes
    while IFS= read -r line; do
        if [[ -f "$line" && "$line" == /var/log/* ]]; then
            echo "Arquivo de log: \"${line}\" hash: $(get_hash "$line")"
        fi
    done < <(grep '^/var/log/' "$temp_file")
}

# Funcção de busca
forensic_search() {
    echo -e "\e[33;1m[AVISO]\e[0;1m: Talve seja presciso permissões de root.\e[0m"

    # buscando nos diretórios temporários
    echo "Olhando locais padrão"
    standard_files

    echo "Buscando arquivos de log"
    query_logs
}

# Verificar dependências
check_dependencies

# Exibir e encerrar se houver erros
if [[ ${#ERROR[@]} -ne 0 ]]; then
    for e in "${ERROR[@]}"; do
        msg_error "${e}"
    done
    exit 1
fi

directory_is_valid

# Caso seja necessário adicionar mais lógica ao script
echo -e "\e[1;32mTodas as dependências foram verificadas com sucesso!\e[0m"

forensic_search
clean_temp
