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
standart_files() {
    local standart_directorys=("/tmp" "/var/tmp")
    local standart_dir=("/tmp" "/var/tmp")
    local results=()

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

    for dir in ${standart_dir[@]}; do
        results+=("$(find "${dir}" -maxdepth 7)")
    done

    echo "$results" | while IFS= read -r line; do
        if [[ -f "$line" ]]; then
            echo -e "${arch}Arquivo encontrado:${res}${bol} ${line}${res}"

        elif [[ -d "$line" ]]; then
            echo -e "${dire}Diretório encontrado:${res}${bol} ${line}${res}"
        else
            echo -e "${bol}Outro tipo encontrado: ${line}${res}"
        fi
    done
}

# Funcção de busca
forensic_search() {
    echo -e "\e[33;1m[AVISO]\e[0;1m: Talve seja presciso permissões de root.\e[0m"

    # buscando nos diretórios temporários
    standart_files
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
