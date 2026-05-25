# Documentação da Ferramenta `easy_fclone.sh`

## Introdução

`easy_fclone.sh` é uma ferramenta desenvolvida em Bash para clonagem forense de 
volumes e unidades de disco, dividindo os dados em segmentos com cabeçalhos de 
verificação de integridade. Suporta restauração da imagem original a partir dos 
segmentos.

## Funcionalidades

- **Clonagem segmentada**: Divide os dados em segmentos com tamanho configurável.
- **Restauração**: Reconstrói a imagem original a partir dos segmentos.
- **Cabeçalhos de verificação**: Cada segmento contém modelo, número serial, hash 
  do segmento e hash do volume completo.
- **Verificação de integridade**: SHA3‑256 em cada segmento e no volume completo.
- **Hash em paralelo**: A hash do volume é calculada em segundo plano durante a 
  leitura dos segmentos.
- **Buffer configurável**: Ajusta o desempenho da leitura/gravação.
- **Notas**: Permite adicionar notas descritivas ao cabeçalho de cada segmento.

---

## Requisitos

- Linux
- Bash 4.0+
- `dd`, `openssl`, `uuidgen`/`dbus-uuidgen`, `lsblk`, `fdisk`, `numfmt` (coreutils)
- Root apenas para modo clone (acesso a dispositivo)

---

## Uso

### Clone
```bash
sudo ./easy_fclone.sh -s <dispositivo> -d <pasta> -S <tamanho> -B <buffer> -n <nome> [-N <notas>]
```

### Restore
```bash
./easy_fclone.sh -r -s <pasta_dos_segmentos> -d <arquivo_saida>
```

### Opções

| Opção | Descrição |
|-------|-----------|
| `-s <origem>` | Dispositivo (clone) ou diretório de segmentos (restore) |
| `-d <destino>` | Diretório de saída (clone) ou arquivo de imagem (restore) |
| `-S <tamanho>` | Tamanho de cada segmento (ex.: `1G`, `500M`) |
| `-B <tamanho>` | Tamanho do buffer para dd (ex.: `32M`, `64K`) |
| `-n <nome>` | Prefixo dos arquivos de segmento |
| `-N <notas>` | Notas opcionais para o cabeçalho |
| `-r` | Modo restore |
| `-h` | Exibe ajuda |
| `-V`, `--version` | Exibe a versão |

---

## Exemplos

```bash
# Clonar /dev/sda com segmentos de 1 GB e buffer de 32 MB
sudo ./easy_fclone.sh -s /dev/sda -d /backups -S 1G -B 32M -n caso -N "12345"

# Restaurar a partir dos segmentos
./easy_fclone.sh -r -s /backups -d /imagem_restaurada.img

# Ver versão
./easy_fclone.sh --version
```

---

## Tamanhos recomendados

### Tamanho de segmento
- **Pequenos (100 MB)**: Facilitam transferência em redes instáveis.
- **Grandes (1 GB)**: Menos arquivos, menor sobrecarga no sistema de arquivos.

### Tamanho de buffer
- **Pequeno (1 MB)**: Menor consumo de RAM.
- **Grande (32 MB)**: Maior velocidade em discos rápidos.

---

## Licença

Distribuído sob licença MIT. Veja o arquivo `LICENSE` para detalhes.

## Repositório

https://github.com/Erik-Castro/easy_tools.git
