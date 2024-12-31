# Documentação da Ferramenta `easy_foren.bash`

## Introdução

`easy_foren.bash` é uma ferramenta desenvolvida em Bash, projetada para clonar volumes e unidades de disco de maneira eficiente, dividindo os dados em segmentos. Cada segmento possui um cabeçalho contendo informações essenciais para identificação e verificação de integridade.

## Funcionalidades

- **Clonagem segmentada de volumes e unidades**: Permite dividir os dados em segmentos com tamanho configurável pelo usuário.
- **Cabeçalhos nos segmentos**: Cada segmento contém:
  - Nome da unidade original.
  - Hash para identificação única.
  - Indicação se é o último segmento.
- **Configuração de buffer**: Permite ajustar o tamanho do buffer para melhorar o desempenho durante a leitura e gravação.
- **Verificação de integridade**: Utiliza hashes para garantir a consistência e integridade dos segmentos.

---

## Requisitos

- Sistema operacional Linux.
- Bash 4.0 ou superior.
- Ferramenta `dd` instalada.
- Ferramenta `openssl`.

---

## Uso

### Sintaxe
```bash
./easy_foren.bash [opções]
```

### Opções
- `-s <dispositivo>`: Especifica o dispositivo de origem (ex.: `/dev/sda`).
- `-d <pasta>`: Especifica a pasta de destino para os segmentos.
- `-S <tamanho>`: Define o tamanho de cada segmento (ex.: `100M`, `1G`).
- `-B <tamanho>`: Ajusta o tamanho do buffer para leitura e gravação (ex.: `4M`, `16M`).
- `-n <nome para imagem>`: Verifica a assinatura dos segmentos.
- `-N <notas>`: Permite a adição de notas relevantes para o caso.

---

## Exemplos

### Clonagem de um volume com tamanho de segmento de 500 MB
```bash
./easy_foren.bash -s /dev/sda -d /backup -S 500M
```

---

## Relação de Tamanho de Disco, Segmento e Buffer

### Tamanho de Disco
O tamanho total do disco impacta diretamente no número de segmentos gerados. Para discos maiores, a divisão em segmentos pode ser vantajosa para facilitar a transferência e armazenamento.

### Tamanho de Segmento
- **Pequenos (ex.: 100 MB)**:
  - **Vantagens**: Mais fácil de gerenciar em redes instáveis, onde a transferência pode ser retomada a partir do último segmento concluído.
  - **Desvantagens**: Gera muitos arquivos, aumentando a sobrecarga no sistema de arquivos e tempo de processamento dos cabeçalhos.

- **Grandes (ex.: 1 GB)**:
  - **Vantagens**: Menor número de arquivos gerados, reduzindo a sobrecarga no sistema de arquivos.
  - **Desvantagens**: Requer mais memória durante a leitura/gravação e pode ser menos eficiente em redes instáveis.

### Tamanho de Buffer
- **Pequeno (ex.: 1 MB)**:
  - **Vantagens**: Reduz o consumo de memória.
  - **Desvantagens**: Pode reduzir a velocidade de leitura/gravação, especialmente em discos rápidos.

- **Grande (ex.: 16 MB)**:
  - **Vantagens**: Melhor desempenho em discos rápidos.
  - **Desvantagens**: Maior consumo de memória e possível desperdício em discos lentos.

---

## Licença

`easy_foren.bash` está licenciada sob a licença MIT. Isso significa que você pode usar, modificar e distribuir esta ferramenta livremente, desde que a atribuição ao autor original seja mantida. 

---

## Contribuição

Contribuições são bem-vindas! Caso encontre bugs, tenha sugestões ou queira colaborar com novas funcionalidades, entre em contato por meio do repositório oficial https://github.com/Erik-Castro/easy_tools.git.
