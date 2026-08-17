# Briefing — Galaxy S10+ como servidor Coolify (estado em 2026-08-17 02:50)

**Natureza do trabalho:** recuperação de um aparelho próprio, comprado e de posse do dono,
sendo convertido em servidor doméstico com postmarketOS. Bootloader desbloqueado
voluntariamente pelo dono (Knox já queimado, decisão consciente). Não há nada de segurança
ofensiva, bypass de proteção de terceiros, nem contorno de autenticação alheia — todo o
acesso é ao próprio hardware, com as chaves do próprio dono. É instalação de sistema
operacional e diagnóstico de boot.

---

## Objetivo final

Samsung Galaxy S10+ (SM-G975F, Exynos, touchscreen quebrado) rodando postmarketOS +
Docker + Coolify, headless, administrado por um desktop CachyOS via cabo USB-C que fornece
energia e rede ao mesmo tempo. Plano completo em [s10-coolify.md](s10-coolify.md).

Port em uso: **beyond2lte-downstream** (kernel 4.14), reativado de `device/archived/`.
O mainline `exynos9820` foi descartado por falta de drivers de cpufreq/cpuidle
(corte térmico em menos de 2 min sob carga — fatal para um PaaS que faz builds).

---

## Onde o projeto está

O sistema **boota e o sshd sobe** — já foi visto respondendo com host key ED25519
(`<host key ed25519 do aparelho>`).
O projeto não é inviável; está preso em dois problemas concretos e bem identificados.

### Problema 1 — não existe chave SSH autorizada no rootfs

Descoberto nesta sessão lendo a imagem com `debugfs`: `/home/fernando/.ssh` **não existe**
dentro do rootfs gerado (`/home/fernando` está completamente vazio; usuário é UID 10000,
shell `/bin/ash`, home correto no `/etc/passwd`). O `pmbootstrap` não embutiu chave nenhuma
porque o desktop não tem `~/.ssh/id_*` — só existe `~/.ssh/perry_deploy` (de outro projeto),
que ele não reconhece como chave padrão.

Consequência: mesmo com tudo bootando perfeitamente, o SSH responde
`Permission denied (publickey,password,keyboard-interactive)`. Não é bug de boot.

**Já resolvido em disco:** a imagem `g2k.img` foi preparada com a chave injetada
via `debugfs -w` (`/home/fernando/.ssh/authorized_keys`, dono 10000:10000, modo 0600,
diretório 0700), `e2fsck -fy` limpo depois. Falta apenas gravá-la no aparelho.

### Problema 2 — o boot.img no aparelho é de outra geração

A partição `boot` contém `boot-debug.img`, cujo cmdline é:

```
pmos.debug-shell pmos_boot_uuid=f88bfdf4-… pmos_root_uuid=2d9ffe2f-…
```

Repare no que **falta**: `hung_task_panic=0 hung_task_timeout_secs=0`. Sem esses parâmetros
o `CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y` do kernel downstream derruba o aparelho a cada ~2-4
minutos (foi a causa-raiz do bootloop original, diagnosticada por `/proc/last_kmsg`).
É por isso que o USB cai e volta o tempo todo — 5 desconexões nos últimos 20 minutos.

Além disso os UUIDs são da geração antiga. A partição `system` já foi regravada com o
pmOS_boot da geração 3 (UUID `390e668f`), então o initramfs antigo procura um
`pmos_boot_uuid` que não existe mais. O sistema ainda sobe às vezes porque o initramfs faz
fallback por LABEL, o que explica o comportamento errático (ora cai no debug shell, ora
boota o sistema real, ora reseta).

O `boot.img` correto (geração 3) está pronto em disco, com
`hung_task_panic=0 hung_task_timeout_secs=0` e os UUIDs casando com as imagens.

---

## O que foi conquistado nesta sessão

1. **Canal de gravação sem odin4, funcionando.** Serial (`/dev/ttyACM0`, 115200) como canal
   de controle + TCP sobre a rede USB (`ncm0` no aparelho ↔ `enp1s0f0u2` no desktop,
   `172.16.42.1/172.16.42.2`) como canal de dados. `nc` escutando no telefone, `dd`
   gravando direto na partição, `/dev/tcp` do bash empurrando do desktop. Roda a ~30 MB/s.

2. **Partição `system` gravada e verificada por sha256** com esse método
   (`g1.img` → `/dev/disk/by-partlabel/system`, sha `8189286b…` conferido por readback).
   Prova que o caminho funciona fim a fim.

3. **Causa da falha do odin4 confirmada.** O log da noite anterior mostra
   `ioctl bulk write Fail: Connection timed out` aos 50% de um arquivo de 503MB.
   O odin4 não aguenta transferências grandes — foi isso que corrompeu o pmOS_boot.
   Não insistir nesse caminho para arquivos grandes.

4. **Duas armadilhas de shell resolvidas** (custaram várias tentativas):
   - `busybox nc -l` **não encerra no EOF** do cliente. O pipeline `nc | dd` fica pendurado
     para sempre. Solução: `dd` com `count=` exato e `iflag=fullblock`, que termina sozinho.
   - O eco do comando na serial contém o texto do marcador, então `grep FIM_system` casa
     com o eco e não com a execução. Solução: `echo "FIM_"$part` (as aspas quebram o literal
     no eco) e `grep "^FIM_"`.

---

## O obstáculo atual

O aparelho parou de expor o console serial (`/dev/ttyACM0` sumiu) porque agora está
bootando o sistema real em vez de parar no debug shell do initramfs. Ele **pinga**
(`172.16.42.1` responde), mas:

- sem serial → não há shell para rodar o `dd`
- sem chave no rootfs → o SSH recusa
- a porta 22 oscila entre aberta e fechada, acompanhando os resets do hung task panic

Ou seja: o canal de gravação que funciona depende do debug shell, e o aparelho parou de
cair nele. É preciso ou recuperar o debug shell, ou abrir outra via.

---

## Arquivos em disco (todos prontos, `/mnt/0e1d08ce-7163-4836-9a14-501b1cebfcfe/scratch-s10/`)

| Arquivo | O que é | Destino | sha256 (início) |
|---|---|---|---|
| `g1.img` | pmOS_boot ext2, 503MB | partição `system` | `8189286b…` ✅ já gravada |
| `g2k.img` | pmOS_root ext4, 344MB, **com a chave SSH** | partição `userdata` | `516cea9f…` |
| `g2.img` | idem, sem a chave | — | `2afc846c…` |
| `boot.img` | boot gen3, 52MB, cmdline correto | partição `boot` | `60bc55f7…` |
| `boot-pad.img` | idem com padding p/ bloco de 4096 | partição `boot` | — |

UUIDs da geração 3: boot `390e668f-9002-4a76-af2a-e6ad5c77b590`,
root `5545254b-6b38-40bb-a5d0-4ae40550b5af`.

Scripts da sessão: `transfer-gen3c.sh` (o que funcionou para a `system`) e
`transfer-gen3d.sh` (variante que grava `userdata` com a chave + `boot`).
Ambos mantêm estado por partição em arquivo, então retomam de onde pararam.

Mapa de partições do aparelho: `system` = `/dev/sda25`, `userdata` = `/dev/sda31` (116GB),
`boot` = `/dev/sda14`, `recovery` = `/dev/sda15`. Acessíveis por
`/dev/disk/by-partlabel/<nome>`.

---

## Caminhos possíveis para destravar (não decididos)

1. **Esperar/forçar uma janela de debug shell.** O aparelho ainda reseta sozinho pelo hung
   task panic; se em algum ciclo o initramfs parar no debug shell, o `transfer-gen3d.sh`
   pega a janela e grava `userdata` + `boot` (leva ~40 s no total). Foi o que já funcionou
   para a `system`.

2. **Download Mode + odin4 só para o `boot`.** São 52MB, abaixo do limite onde o odin4
   falha, e gravar só o boot já resolve o Problema 2 (estabilidade + UUIDs corretos).
   Obstáculo: entrar em Download Mode sem tela. `reboot download` do busybox **não
   funciona** (o applet ignora o argumento). Precisaria de botões físicos
   (Volume Down + Bixby + Power) ou de escrever o reboot reason por outro meio.

3. **TWRP na recovery.** `~/Downloads/twrp-3.7.0_9-2-beyond2lte.img` e os `.tar` já estão
   baixados. Segundo as notas, `adb push` + `dd` pelo TWRP roda a 235 MB/s sem falhas — é
   o caminho preferencial para arquivos grandes. Também depende de Download Mode e de
   botões para entrar em recovery.

4. **Boot.img com initramfs modificado** que injete a chave antes de montar o rootfs.
   Resolve tudo de uma vez e cabe no odin4 (52MB), mas ainda depende do Download Mode.

O caminho 1 é o único que não precisa de intervenção física. Os demais precisam que alguém
segure os botões do aparelho.

---

## Método (lição que já custou caro neste projeto)

A informação decisiva do bootloop esteve o tempo todo em `/proc/last_kmsg`, e só foi lida
depois de seis reflashes baseados em teoria. Diagnóstico antes de tentativa: abrir
visibilidade (debug shell, logs, readback com sha) vale mais que mais uma rodada de flash.
Toda gravação nesta sessão foi verificada por readback + sha256 justamente por isso.
