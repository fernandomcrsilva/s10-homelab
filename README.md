# Galaxy S10+ como servidor doméstico

Um Samsung Galaxy S10+ (SM-G975F, Exynos 9820) com a tela quebrada, convertido em
servidor caseiro headless com postmarketOS.

O aparelho roda NAS por Samba, interface web de arquivos, bloqueio de anúncios para toda
a rede e monitoramento — servindo arquivos a **60 MB/s por WiFi**, consumindo **0,39 W**
em repouso e com autonomia de aproximadamente um dia sem tomada, porque a bateria virou
no-break embutido.

## O que roda

| Serviço | Função |
|---|---|
| Samba | compartilhamento de arquivos na rede |
| filebrowser | interface web de arquivos (upload, preview, download) |
| AdGuard Home | DNS com bloqueio de anúncios para a rede inteira |
| netdata | monitoramento em tempo real (CPU, temperatura, rede, disco) |
| Tailscale | acesso remoto sem abrir portas no roteador |

Tudo sobe sozinho no boot, validado por reinicialização completa.

## Números medidos

- **Escrita:** 60,8 MB/s · **Leitura:** 49,3 MB/s (WiFi 5 GHz, sobre SSH)
- **Latência:** 4 ms (era 70–255 ms antes de desligar o power save do WiFi)
- **Consumo:** 91 mA a 4,28 V = 0,39 W em repouso
- **Temperatura:** 30–36 °C sob operação normal
- **Espaço:** 103 GB úteis dos 128 GB internos

Para comparação, um Raspberry Pi 4 ocioso consome de 3 a 5 W.

## As três armadilhas que custaram caro

Este repositório existe principalmente por causa destas. Todas consumiram horas e nenhuma
está documentada de forma óbvia em outro lugar.

### 1. O bootloader da Samsung ignora o cmdline do boot.img

O kernel downstream traz `CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y`, que derrubava o aparelho a
cada 2–4 minutos. A correção parece ser passar `hung_task_panic=0` no cmdline do
`boot.img` — e **não funciona**. O bootloader descarta esse cmdline e injeta o seu próprio
(`androidboot.*`), como se vê em `/proc/cmdline`.

Seis reflashes foram feitos sobre essa premissa errada antes de alguém ler o
`/proc/cmdline`. A correção que funciona é em espaço de usuário:

```sh
# /etc/sysctl.d/99-hungtask.conf
kernel.hung_task_panic = 0
kernel.hung_task_timeout_secs = 0
```

O serviço `sysctl` já está no runlevel `boot`, e o timeout de 120 s dá margem de sobra
para ele ser aplicado antes do primeiro panic.

### 2. O driver de WiFi não fala a API antiga

`iwlist` e `iwconfig` respondem `no wireless extensions` / `Interface doesn't support
scanning` no `bcmdhd` da Samsung — o que parece rádio quebrado e não é. O driver usa
nl80211; a ferramenta certa é o `iw`:

```sh
apk add iw
iw dev wlan0 scan | grep SSID
```

O firmware (`firmware-samsung-beyond2lte`) já vem instalado e no lugar certo. A interface
estava apenas `down`.

E depois de conectar, **desligue o power save** — sem isso o ping oscila entre 70 e 255 ms:

```sh
iw dev wlan0 set power_save off   # persistir em /etc/local.d/
```

### 3. O `conf.d` do OpenRC não vence o init script

O OpenRC carrega `/etc/conf.d/<serviço>` **antes** de executar o init script. Qualquer
variável que o init script defina diretamente sobrescreve o que você pôs no `conf.d`.

O `/etc/init.d/filebrowser` traz `command_user="filebrowser:filebrowser"` fixo, então o
serviço ignorava a configuração e rodava como o usuário errado — falhando ao acessar
arquivos, sem escrever nada em log. O sintoma era só `status: crashed`.

Para ver o erro real, declare os logs no `conf.d`:

```sh
output_log="/var/log/servico/out.log"
error_log="/var/log/servico/err.log"
```

## Detalhes por serviço

- **AdGuard Home:** o roteador anuncia a si mesmo como DNS IPv6 via Router Advertisement,
  e os clientes preferem IPv6 — então o bloqueio é contornado silenciosamente, mesmo com o
  DHCP apontando para o AdGuard. Roteadores de operadora frequentemente não permitem
  desligar isso. A saída é fixar o DNS por cliente (`ipv4.ignore-auto-dns yes` +
  `ipv6.ignore-auto-dns yes` no NetworkManager).
- **filebrowser 2.27.0:** o CSS empacotado vem com `__VITE_ASSET__` literal no lugar da URL
  da fonte, e os ícones aparecem como texto. Contornável via `--branding.files` com um
  `custom.css` que embute a fonte. O banco é BoltDB: aceita um processo por vez, então
  `config set` com o serviço no ar falha por timeout silenciosamente.
- **Bateria:** `echo 60 > /sys/class/power_supply/battery/batt_full_capacity` limita a
  carga — é o mesmo mecanismo do "Proteger bateria" do One UI. Importante para um aparelho
  que fica permanentemente na tomada.
- **netdata:** configurado com `[db] mode = ram`. O storage interno não é substituível, e
  não vale gastá-lo gravando métricas.

## Sobre o load average

O sistema mostra load average em torno de 11 com a CPU 97% ociosa e o aparelho a 30 °C.
São threads de kernel do TrustZone da Samsung (`tz_worker_thread`, `tz_iwsock`,
`ree_time`) presas em estado `D`, esperando um secure world que o postmarketOS nunca
inicializa. Estado `D` entra no cálculo do load sem consumir CPU. É cosmético.

## Ferramentas de gravação

O `odin4` falha em arquivos grandes (`ioctl bulk write Fail` por volta dos 50% em um
arquivo de 503 MB), mas funciona bem para imagens pequenas. Para o resto, o TWRP na
recovery é o caminho confiável: root sem senha, `adb push` a ~35 MB/s e `dd` a 157 MB/s.

Combinações de botões (com a tela quebrada, é às cegas):

- **Download Mode:** Volume Baixo + Bixby + Power
- **Recovery:** Volume Cima + Bixby + Power

## Estrutura

```
docs/
  plano-tecnico.md      análise mainline vs downstream, topologia, fases
  recuperacao-boot.md   diagnóstico do bootloop e técnicas de gravação
scripts/
  wifi-s10.sh           conecta o aparelho ao WiFi (senha vira hash local)
  recuperacao/          scripts da fase em que o sistema reiniciava sozinho
```

Os scripts em `recuperacao/` esperavam janelas de conectividade de dois minutos entre
reinicializações. Depois que o `sysctl.d` resolveu o problema na raiz, ficaram obsoletos —
estão aqui como registro da técnica, que pode servir a quem enfrentar um aparelho instável.

## Aviso

Os endereços de rede nos documentos foram trocados por exemplos. Ajuste para a sua rede
antes de usar qualquer script.

Este é o registro de um aparelho específico. Bootloader desbloqueado significa Knox
queimado permanentemente e garantia perdida — decisão consciente de quem é dono do
aparelho.
