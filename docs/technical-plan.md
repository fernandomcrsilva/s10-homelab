# Galaxy S10+ (Exynos) como servidor Coolify

Servidor headless rodando postmarketOS + Docker + Coolify, administrado a partir do
desktop. O celular é o servidor; o PC é o cliente.

**Critério de sucesso:** UI do Coolify acessível do desktop, aparelho estável plugado por
uma semana sem intervenção física, bateria não passando de ~70%.

> **Revisão de 2026-08-15.** O plano original assumia portar `beyond1lte` → `beyond2lte`
> sobre kernel downstream 4.14. Descoberto durante a execução: o pmaports consolidou tudo
> em `device-samsung-exynos9820`, um port **mainline genérico** que já declara
> `provides="device-samsung-beyond2lte"`. Não há porte a fazer. Em compensação, o kernel
> mainline vem sem várias coisas que o downstream tinha prontas. Ver Fase 2.

## Escolha do port — leia antes

| | `exynos9820` (mainline) | `beyond2lte-downstream` (arquivado) |
|---|---|---|
| Estado | `testing`, adicionado **2026-07-11**, 1 commit | Arquivado em 2026-07-12 |
| Kernel | 7.2.0 mainline | 4.14 Android (2021), sem patches |
| Docker | **Falta** OVERLAY_FS, BRIDGE, netfilter — corrigível por config | Tudo presente de fábrica |
| Wifi | `BRCMFMAC` não compilado — incerto | `BCM_DHD_WLAN` + `BCM4375` prontos |
| Charge limit | `constant_charge_voltage` (por tensão) | `store_mode` (histerese 60–70%) |
| Init | OpenRC (o `systemd-boot` da dep é bootloader, não init) | OpenRC |
| Manutenção | Ativa, mas embrionária | Nenhuma |

**Escolhido: downstream** (revisto em 2026-08-16, durante a execução).

A escolha inicial foi o mainline, por segurança. Ela caiu quando o MR do port
([pmaports!8999](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/8999))
revelou dois impedimentos que nenhum config denuncia:

1. **Corte térmico.** Palavras do autor: *"there is no cpuidle, cpufreq or cpuhp support.
   Stressing all 8 cores (…) bakes the SoC very quickly and it goes into thermal protection
   (hard power cutoff) (…) in under 2 minutes."* Daí o `maxcpus=6` no cmdline. Para um PaaS
   que vive fazendo `docker build`, isso ataca exatamente o caso de uso.
   Cuidado ao ler o kconfig: `CPU_FREQ`/`CPU_IDLE`/`THERMAL` aparecem `=y` nos **dois**
   configs — isso é só o framework. Os drivers do Exynos 9820 é que faltam no mainline.
2. **Boot exige u-boot próprio.** O mainline boota por EFI a partir de um u-boot
   customizado com driver UFS (`chiffathefox/u-boot`, branch `exynos9820`), compilado à
   parte e gravado na partição `boot`. Não existe `boot.img` no rootfs — foi exatamente
   nisso que o instalador recovery-zip falhou (`dd: can't open /mnt/pmOS/boot/boot.img`).

O downstream, em contraste: drivers térmicos da Samsung completos, wifi confirmado
funcionando pelo autor do port, `flash_method="heimdall-bootimg"` com
`generate_bootimg="true"` (logo o recovery-zip completa), e o kernel 4.14 já traz quase
todos os requisitos de container de fábrica.

**Custo aceito:** kernel de 2021 sem patches de segurança, e port arquivado. Mitigável por
ser um servidor doméstico atrás de NAT.

**Como reativar** (feito): copiar `device-samsung-beyond2lte-downstream`,
`linux-samsung-beyond2lte-downstream` e `firmware-samsung-beyond2lte` de
`device/archived/` para `device/testing/` e **apagar os originais** — pacote em duas
pastas faz o pmbootstrap abortar com "found in multiple aports subfolders".

## Topologia

Cabo USB-C do celular pra porta **traseira** da placa-mãe: energia e link de administração
no mesmo cabo. Celular em modo gadget, `172.16.42.1`, SSH por padrão.

- **Energia**: a porta USB-C. Validado no Android — bateria subiu sob carga.
- **Administração**: USB gadget, link ponto-a-ponto. Sempre disponível.
- **Internet**: sem `BRCMFMAC` compilado, o wifi é incerto. Plano primário passa a ser
  **NAT no PC** (apêndice) — coerente com a topologia, já que o aparelho vive plugado.
  Se o wifi funcionar depois de habilitado, melhor: vira independente do PC.
- **Acesso**: SSH e Coolify (`:8000`) em `172.16.42.1`.

---

# Fase 0 — Antes de tocar em qualquer coisa

## O que é irreversível

Desbloquear o bootloader **queima o e-fuse do Knox, permanentemente**. Não existe desfazer,
nem reflashando stock. Some pra sempre: Samsung Pay, Secure Folder, e apps de banco que
checam Knox.

Ativar o toggle "OEM Unlocking" **não** queima nada — o e-fuse só vai na Fase 3, quando
você confirmar o aviso no Download Mode.

## Checklist

| Verificar | Estado |
|---|---|
| Modelo é Exynos | ✅ confirmado |
| OEM Unlock ativado | ✅ feito |
| Porta do PC aguenta | ✅ bateria subiu sob carga no Android |
| Bateria sã (sem estufamento) | ⬜ inspeção visual |
| Firmware stock baixado | ⬜ **pendente — é o único caminho de volta** |
| TWRP `beyond2lte` baixado | ⬜ pendente |

**Firmware stock (Linux):** CSC via `*#1234#` no discador (BR costuma ser `ZTO`), depois o
binário do [samloader](https://github.com/samloader/samloader/releases):

```bash
./samloader -m SM-G975F -r <CSC> checkupdate
./samloader -m SM-G975F -r <CSC> download -v <versão> -O ~/Downloads/stock
```

**TWRP:** `twrp-*-beyond2lte.img.tar` em <https://twrp.me/samsung/samsunggalaxys10plus.html>.
Confira o codename — beyond0lte (S10e) e beyond1lte (S10) também estão listados e o errado
não boota.

---

# Fase 1 — Preparar o desktop ✅

```bash
sudo pacman -S --needed pmbootstrap heimdall android-tools
pmbootstrap init
```

Work path: `/mnt/0e1d08ce-7163-4836-9a14-501b1cebfcfe/pmbootstrap` (o root só tem ~14GB
livres; o default `~/.local/var/pmbootstrap` encheria o disco no build).

Respostas: channel `edge` · vendor `samsung` · codename **`exynos9820`** · UI `none` ·
extra `openssh` · SSH key `y` · FDE **`n`** (sem tela, não dá pra digitar senha no boot).

O init pergunta providers de mais de um pacote — leia o nome do pacote antes de responder:

| Provider de | Responder |
|---|---|
| `postmarketos-base-ui-audio-backend` | Enter (`pulseaudio`). Irrelevante sem UI. |
| `postmarketos-base-ui-wifi` | Enter (`wpa_supplicant`). |
| `postmarketos-usb-moded-default-profile` | **`developer`** — já é o default |

Em "Additional options", responda `y` e ponha **`sudo timer: True`** (evita redigitar senha
durante os builds). O resto aceita com Enter.

Service manager: **OpenRC**. O `systemd-boot` nas dependências do device é bootloader,
não init.

O `developer` é crítico: o perfil `charging` exige habilitar o USB networking manualmente,
o que num aparelho sem tela é circular — você precisaria de acesso pra criar o acesso.

---

# Fase 2 — Ajustar o kernel ✅ CONCLUÍDA

Kernel `7.2.0-r0` compilado e verificado no `boot/config` do `.apk`: `OVERLAY_FS=m`,
`NF_TABLES_IPV4=y`, `NFT_COMPAT=m`, `NF_NAT=y`, `BRIDGE=m`, `VETH=y`, cgroups/namespaces
completos, USB gadget (RNDIS/NCM/DWC3), `BRCMFMAC=m`, `CHARGER_MAX77705=y`.
Foram **duas** rodadas de build — a primeira passou no `kconfig check` mas saiu sem rede
para container. Leia a seção do iptables legacy abaixo antes de repetir isso noutro device.


Substitui o antigo "porte do pacote": não há porte a fazer, mas o config mainline foi
enxugado pra telefone e falta o que Docker precisa.

**Não monte a lista à mão.** O pmbootstrap já traz os requisitos oficiais de container em
`kconfigcheck.toml` (categoria `containers`, ~70 opções — bem mais que as 9 óbvias):

```bash
pmbootstrap kconfig check --categories containers linux-postmarketos-exynos9820
```

No estado original faltavam **44**. Foram aplicadas ao
`config-postmarketos-exynos9820.aarch64` lendo os valores direto do TOML, mais
`BRCMFMAC`/`BRCMFMAC_SDIO`/`BRCMUTIL` como tentativa de wifi. Cinco opções ficaram em `y`
onde o TOML pedia `m` (`VETH`, `NF_NAT`, `NETFILTER_XT_MARK`, `XT_MATCH_CONNTRACK`,
`NET_CLS_CGROUP`) — `y` é mais forte, o check aceita como INFO.

Backup do config original: `scratchpad/config-exynos9820-ORIGINAL.bak`. Não deixe `.bak`
no diretório do pacote — o validador tenta interpretá-lo como config e falha.

O config está no `source=` do APKBUILD, logo tem `sha512sum` registrado: **editar o config
sem regenerar o checksum faz o build falhar.** E `build` sem `--force` não faz nada — o
pmbootstrap compara versão, não conteúdo, e considera o pacote "up to date":

```bash
pmbootstrap checksum linux-postmarketos-exynos9820 && \
pmbootstrap build linux-postmarketos-exynos9820 --force
```

**Gate:** compila **e** as opções sobreviveram. Não confie no `kconfig check` para isto:
ele valida o arquivo de texto, não o Kconfig real do kernel. Extraia `boot/config` do
`.apk` gerado e compare — é a única fonte de verdade.

### O iptables legacy não existe no kernel 7.2

Na primeira rodada, 16 das 44 opções sumiram do kernel compilado. Não foram desabilitadas:
**não existem** no Kconfig do 7.2. As tabelas legacy do iptables (`IP_NF_FILTER`,
`IP_NF_NAT`, `IP_NF_MANGLE`, `IP_NF_RAW`, `IP_NF_TARGET_MASQUERADE`,
`IP_NF_TARGET_REDIRECT` e os equivalentes `IP6_NF_*`, mais `NFT_NAT`, `NFT_FIB*`,
`BRIDGE_VLAN_FILTERING`) foram removidas. Sobraram só matches pontuais.

O `kconfigcheck.toml` do pmaports foi escrito para kernels com iptables legacy e não
reflete isso — por isso o check "passou" enquanto o kernel real não tinha nada daquilo.

No 7.2 tudo passa por **nftables**, com `NFT_COMPAT` traduzindo as chamadas do userspace.
O que de fato precisa estar ligado, e vinha desligado:

```
CONFIG_NF_TABLES_IPV4=y      # sem isto NÃO HÁ NAT ipv4 — Docker não faz port mapping
CONFIG_NF_TABLES_IPV6=y
CONFIG_NF_TABLES_INET=y
CONFIG_NF_TABLES_BRIDGE=m
CONFIG_NFT_REDIR=m
CONFIG_NFT_REJECT=m
CONFIG_NFT_LOG=m
CONFIG_NFT_LIMIT=m
CONFIG_VLAN_8021Q=m
```

Já vinham corretos: `NF_TABLES=m`, `NFT_COMPAT=m`, `NFT_MASQ=m`, `NFT_CT=m`,
`NF_NAT_MASQUERADE=y`, `IP_NF_IPTABLES=y`, `IP6_NF_IPTABLES=y`.

As 16 inexistentes seguem escritas no config — o Kbuild as ignora, são inócuas. Ficam ali
só para o `kconfig check` não travar builds futuros. **Não são prova de nada.**

---

# Fase 3 — Instalar e flashar

Ponto sem volta. Daqui em diante, voltar significa flashar firmware stock.

**O rootfs não vai por heimdall** (`flash_method="none"`: *"Heimdall fails mid-transfer when
flashing rootfs. Use TWRP instead"*). Vai como **zip via ADB sideload no TWRP**, conforme o
wiki do device. O heimdall só serve pra pôr o TWRP na recovery.

## 3.1 Gerar o zip

```bash
pmbootstrap install --android-recovery-zip --recovery-install-partition data
```

Instalar na partição `data` é o que dá espaço ao Docker — é a maior do aparelho (~100GB).
Saída: `pmos-samsung-exynos9820.zip` (nosso codename é `exynos9820`; o wiki ainda descreve
o port antigo `beyond2lte` out-of-tree, mas o procedimento de flash é o mesmo).

## 3.2 Desbloquear o bootloader — **Knox queima aqui**

Download Mode (desligado → Volume Down + Bixby + Power, ou plugado segurando
Volume Down + Bixby) → Volume Up para confirmar o aviso. O aparelho faz factory reset.

Depois disso, **passe pelo setup do Android e reative o OEM Unlocking** nas opções do
desenvolvedor. O VaultKeeper bloqueia o flash até isso, e o heimdall falha com um erro
que não explica a causa.

## 3.3 TWRP na recovery

Heimdall com a imagem do TWRP para `beyond2lte` (<https://twrp.me/samsung/samsunggalaxys10plus.html>).
Booteie direto no TWRP depois: **Volume Up + Bixby + Power**.

## 3.4 Sideload do pmOS

No TWRP, nesta ordem:

1. **Mount → desmarque `Data`.** O wiki é enfático: a partição precisa estar desmontada.
2. Advanced → ADB Sideload

```bash
adb sideload pmos-samsung-exynos9820.zip
```

**Gate:** `ssh fernando@172.16.42.1` responde. Tela apagada com SSH vivo = sucesso.

---

# Fase 4 — Calibração no hardware

## 4.1 Limite de carga (primeiro, sempre)

O mainline não tem o `store_mode` da Samsung. O driver `max77705_charger` expõe
`CONSTANT_CHARGE_VOLTAGE` — limite por tensão de flutuação, que é o método clássico:

```bash
ls /sys/class/power_supply/*/
# procure constant_charge_voltage (µV). 4400000 ≈ 100%, ~3950000 ≈ 65%
echo 3950000 > /sys/class/power_supply/<charger>/constant_charge_voltage
```

Persista num unit systemd. Confirme que pegou observando `capacity` estabilizar.

Se a propriedade for somente-leitura, o fallback é script de user space alternando
`ONLINE`/`STATUS` por histerese — e aí o downstream (com `store_mode`) volta a ser tentador.

## 4.2 Corrente de entrada

Validado na Fase 0 (bateria subiu sob carga). Se mudar de porta ou cabo, o knob é
`input_current_limit` no mesmo diretório. Confira uma vez sob `docker build` real.

## 4.3 Internet

Tente o wifi primeiro, agora que `BRCMFMAC` foi compilado:

```bash
nmcli device wifi connect "<SSID>" password "<senha>" && ping -c3 1.1.1.1
```

Funcionou? Servidor independente do PC — reserve o IP no roteador pelo MAC.
Não funcionou? Vá pro apêndice (NAT). O link USB é ponto-a-ponto e **não** dá internet
sozinho, e sem internet nada da Fase 5 roda.

## 4.4 Teste de religamento

`poweroff`, reconecte energia, veja se volta sozinho. Descubra agora, não às 3h da manhã.

---

# Fase 5 — Docker + Coolify

## 5.1 Limite de log (antes do primeiro container)

O storage é UFS soldado; se morrer, morreu o servidor. `/etc/docker/daemon.json`:

```json
{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }
```

## 5.2 Coolify

O instalador oficial suporta `postmarketos` nominalmente, com branch dedicado pra OpenRC
(`apk add docker docker-cli-compose` + `rc-update add docker default`):

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sh
```

UI em `http://172.16.42.1:8000`.

**Gate:** UI carrega do desktop e um deploy de teste (imagem `arm64`) sobe.

Ressalva ARM64: parte do catálogo one-click não publica imagem `arm64`. Builda na mão.

---

# Fase 6 — Operação

- **Fora de casa**: `tailscale` → IP estável sem abrir porta.
- **Apps publicados**: Cloudflare Tunnel, integrado no Coolify.
- **Backup**: `/data/coolify` pra fora do aparelho. O UFS é o ponto único de falha.

---

# Rollback

| Situação | Saída |
|---|---|
| Não bootou / sem SSH | Download Mode → Heimdall com o firmware stock da Fase 0 |
| Mainline inviável (Docker/wifi/bateria) | Reativar `device/archived/*beyond2lte-downstream` |
| Kernel quebrado após rebuild | Reflash do kernel anterior |

---

# Riscos conhecidos

| Risco | Estado |
|---|---|
| Knox queimado | Aceito conscientemente. Irreversível. |
| Port mainline com 1 mês de vida | **Aceito** — é o risco central do projeto. Fallback documentado. |
| Charge limit por tensão | **Em aberto** — Fase 4.1. Se a propriedade for read-only, reavaliar. |
| Wifi no mainline | **Em aberto** — Fase 4.3. NAT cobre. |
| Flash por TWRP não documentado aqui | **Em aberto** — confirmar no wiki antes da Fase 3. |
| Não religa sozinho | **Em aberto** — Fase 4.4. |
| Bateria drena com cabo | Descartado — testado no Android. |
| Desgaste do UFS | Mitigado: limite de log + backup externo. |
| Tela não acende | Irrelevante em headless. |

---

# Apêndice — internet pelo cabo (NAT no PC)

Provável caminho principal, dado o wifi incerto. Custo: sem internet quando o PC estiver
desligado.

Neste desktop: saída pela `enp5s0` (192.168.1.10), `ip_forward` já ligado, **ufw ativo**.

Em `/etc/default/ufw`:

```
DEFAULT_FORWARD_POLICY="ACCEPT"
```

No topo de `/etc/ufw/before.rules`, antes do `*filter`:

```
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 172.16.42.0/24 -o enp5s0 -j MASQUERADE
COMMIT
```

```bash
sudo ufw reload
```

No celular:

```bash
ip route add default via 172.16.42.2
echo "nameserver 1.1.1.1" > /etc/resolv.conf
```

---

# Referências

- device mainline: `device/testing/device-samsung-exynos9820` no pmaports
- kernel: https://github.com/chiffathefox/exynos-9820-mainline-linux
- wiki do S10+: https://wiki.postmarketos.org/wiki/Samsung_Galaxy_S10%2B_(samsung-beyond2lte)
- Coolify: https://coolify.io/docs/get-started/installation
