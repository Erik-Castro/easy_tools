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

# Função para exibir mensagens de erro
msg_error() {
    local message="${1:-Algo inesperado aconteceu.}"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if [[ -t 1 ]]; then
        echo -e "\e[1;41m[ERRO]\e[0m: ${message}\t${timestamp}" >&2
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
    for cmd in updatedb locate find xargs cavalo anta girafa; do
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

# Verificar dependências
check_dependencies

# Exibir e encerrar se houver erros
if [[ ${#ERROR[@]} -ne 0 ]]; then
    for e in "${ERROR[@]}"; do
        msg_error "${e}"
    done
    exit 1
fi

# Caso seja necessário adicionar mais lógica ao script
echo "Todas as dependências foram verificadas com sucesso!"
