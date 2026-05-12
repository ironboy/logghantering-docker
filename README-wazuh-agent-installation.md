## Installera Wazuh-agent — manuellt och i Docker

I vår labbmiljö är agenten **redan installerad** i alla offer-containrar.
Den här artikeln går igenom *hur* den installerades — både i de Dockerfiles
du har i repot och hur du skulle göra på en "vanlig" Linux-maskin du
SSH:ar till.

Förståelse för detta är viktigt eftersom:

- I verkligheten ska du *själv* rulla ut agenter på företagets servrar
- Olika base-images kräver olika strategier
- Felsökning av en agent som inte registrerar sig är en återkommande
  SOC-uppgift

> **Pedagogisk ordning:** Vi börjar med det enklaste fallet — en agent på
> en vanlig Linux-maskin. Sen tittar vi på vad agenten faktiskt gör.
> *Sist* går vi in på Docker, som är specialfallet med flera variationer.

---

## Del 1 — Bakgrund: vad är Wazuh-agenten?

Wazuh-agenten är ett litet program (~30 MB installerat) som körs på en
endpoint (server, laptop, container, virtuell maskin) och samlar in:

- **Loggar** — filer du pekar ut med `<localfile>` (auth.log, syslog,
  applikationsloggar)
- **File Integrity Monitoring (FIM)** — `syscheck`-modulen tittar på
  `/etc`, `/bin`, `/sbin` och larmar om filer ändras
- **Security Configuration Assessment (SCA)** — på svenska ungefär
  *säkerhets-konfigurationsutvärdering*. Modulen jämför maskinens
  konfiguration mot en *policy* (en checklista med hundratals regler) och
  larmar för varje regel som inte uppfylls. Vanligast är att man kör
  policys från **CIS** (Center for Internet Security), en branschorganisation
  som publicerar konsensus-baserade härdningsstandarder för i princip alla
  vanliga operativsystem. Skanningen körs vid agentens uppstart och sedan
  var 12:e timme. Resultatet säger inte "någon attackerade oss" — det
  säger "så här såg vårt försvar ut".
- **System inventory** — hårdvara, paket, nätverk, processer
- **Active Response** — kan ta emot kommandon från managern (t.ex.
  blockera en IP via iptables)

Allt detta skickas över **port 1514/tcp** till managern, encrypted med
en pre-shared key (PSK) som agenten får vid registrering.

---

## Del 2 — Manuell installation på en Linux-maskin

Detta är *huvudfallet* i SOC-yrket. En kollega ger dig SSH-åtkomst till
en server och säger "rulla ut Wazuh-agent på den här". Här är hur.

### 2a. Debian / Ubuntu

> **Distro-familj:** Debian och Ubuntu är väldigt nära släkt — Ubuntu är
> byggt ovanpå Debian. De delar **samma pakethanterare (`apt-get` / `apt`)**,
> samma paketformat (`.deb`), och samma repository-struktur. Allt du gör
> mot ett Ubuntu-system fungerar nästan alltid identiskt på Debian och
> tvärtom. Detta är den vanligaste distro-familjen för utvecklingsmiljöer
> och container-baser.

```bash
# Lägg till Wazuh:s GPG-nyckel och repo
curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
    sudo gpg --no-default-keyring \
             --keyring /usr/share/keyrings/wazuh.gpg --import
sudo chmod 644 /usr/share/keyrings/wazuh.gpg

echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
https://packages.wazuh.com/4.x/apt/ stable main" | \
    sudo tee /etc/apt/sources.list.d/wazuh.list

# Installera (med manager-adress i environment så agenten auto-enrollar)
sudo apt-get update
sudo WAZUH_MANAGER='manager.example.com' \
    apt-get install -y wazuh-agent=4.14.4-1

# Starta tjänsten
sudo systemctl daemon-reload
sudo systemctl enable wazuh-agent
sudo systemctl start wazuh-agent
```

### 2b. RHEL / Rocky / Alma / Fedora

> **Distro-familj:** Detta är "Red Hat-familjen" — kommersiella RHEL (Red
> Hat Enterprise Linux) plus dess gratis-kloner Rocky Linux och AlmaLinux,
> samt Red Hats egna utvecklings-distro Fedora. De delar
> **pakethanteraren `dnf` (eller äldre `yum`)** och paketformatet `.rpm`.
> Vanligast i **enterprise- och server-miljöer** — banker, statliga
> myndigheter, telekom. Om du jobbar SOC kommer du *garanterat* möta
> RPM-baserade system, även om du själv mest använt Ubuntu.
>
> Kommandona ser annorlunda ut men koncepten är samma: lägga till en
> nyckel, registrera ett repo, installera ett paket.

```bash
sudo rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH

sudo tee /etc/yum.repos.d/wazuh.repo <<'EOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=Wazuh repository
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF

sudo WAZUH_MANAGER='manager.example.com' \
    yum install -y wazuh-agent-4.14.4

sudo systemctl enable wazuh-agent
sudo systemctl start wazuh-agent
```

### 2c. macOS

> **Distro-familj:** macOS är *Unix-baserat* (precis som Linux) men *inte
> Linux* — egen kernel (XNU), eget filsystem (APFS), egna paketformat
> (`.pkg`-installer). Vanligt på utvecklarmaskiner och designers i moderna
> företag. SOC måste typiskt även övervaka dessa.

Wazuh distribuerar en `.pkg`-installer från `packages.wazuh.com/4.x/macos/`.
Välj rätt arkitektur:

- Intel Mac: `wazuh-agent-4.14.4-1.pkg`
- Apple Silicon (M1/M2/M3): `wazuh-agent-4.14.4-1.arm64.pkg`

```bash
# Ladda ner (exempel för Apple Silicon)
curl -fsSL https://packages.wazuh.com/4.x/macos/wazuh-agent-4.14.4-1.arm64.pkg \
    -o /tmp/wazuh-agent.pkg

# Installera (kräver sudo)
sudo WAZUH_MANAGER='manager.example.com' \
    installer -pkg /tmp/wazuh-agent.pkg -target /

# Starta
sudo /Library/Ossec/bin/wazuh-control start
```

Filer finns på `/Library/Ossec/` (motsvarar `/var/ossec/` på Linux).
Konfig är `/Library/Ossec/etc/ossec.conf`.

### 2d. Windows

> **Distro-familj:** Windows är helt skiljt från Unix-världen. Egen
> kernel (NT), eget filsystem (NTFS), egen pakethantering (MSI/MSIX),
> egen tjänstemodell (Windows Services). Detta är *kärnmål* för SOC i de
> flesta organisationer — Windows-arbetsstationer + Windows Server
> dominerar i de flesta enterprise-miljöer.

Ladda ner `wazuh-agent-4.14.4-1.msi` från `packages.wazuh.com/4.x/windows/`.

I **PowerShell som Administrator**:

```powershell
msiexec.exe /i wazuh-agent-4.14.4-1.msi /q `
    WAZUH_MANAGER='manager.example.com' `
    WAZUH_AGENT_NAME='WIN-WORKSTATION-01'

NET START Wazuh
```

Filer finns på `C:\Program Files (x86)\ossec-agent\`. Konfigfilen ligger
där också (`ossec.conf`).

**Viktigaste skillnaden mot Linux:** du läser **Windows Event Log**, inte
text-filer. Det görs med `<log_format>eventchannel</log_format>`:

```xml
<localfile>
  <location>Security</location>
  <log_format>eventchannel</log_format>
</localfile>
```

Då plockar agenten upp Security-loggen där alla intressanta säkerhets-
events finns:

| Event ID | Vad det betyder |
|---|---|
| 4624 | Lyckad inloggning |
| 4625 | Misslyckad inloggning |
| 4688 | Process skapad |
| 4720 | Ny användare skapad |
| 4732 | Tillagd i lokal admin-grupp |

Wazuh har inbyggda regler för dessa i 60000-serien (motsvarar 31100-
serien för web-loggar). File Integrity Monitoring kan också övervaka
**registry-keys** (`HKEY_LOCAL_MACHINE\Software\...`), inte bara filer.

### 2e. Verifiera att agenten körs

```bash
sudo /var/ossec/bin/wazuh-control status
```

Förväntat svar:

```
wazuh-execd is running...
wazuh-agentd is running...
wazuh-syscheckd is running...
wazuh-logcollector is running...
wazuh-modulesd is running...
```

### 2f. Verifiera att den registrerat sig mot managern

På manager-maskinen, eller via API:n:

```bash
TOKEN=$(curl -k -s -u wazuh-wui:'MyS3cr37P450r.*-' \
    -X POST "https://manager:55000/security/user/authenticate?raw=true")

curl -k -s -H "Authorization: Bearer $TOKEN" \
    "https://manager:55000/agents?pretty=true&select=id,name,status"
```

Du ska se din nya maskin i listan med `status: "active"`.

---

## Del 3 — Konfigurera vad agenten läser

Agenten gör en mängd saker per default (FIM, SCA, inventory). Men för att
få *loggdata* måste du explicit peka ut vilka filer den ska läsa. Det
görs med `<localfile>`-block i `/var/ossec/etc/ossec.conf`.

Exempel — peka ut auth-loggen och syslog:

```xml
<ossec_config>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>
</ossec_config>
```

`<log_format>` säger åt agenten hur den ska tolka raderna. Vanliga
värden:

| log_format | För | Default decoder-stöd |
|---|---|---|
| `syslog` | RFC 3164 / generella textloggar | Begränsat |
| `apache` | Combined Log Format (apache, nginx) | **Bra**, regler 31100-serien |
| `json` | JSON-rader, en per logg | Behöver custom regler oftast |
| `multi-line:N` | Stacktrace, N rader per record | Custom regler oftast |
| `eventchannel` | Windows Event Log | Bra, regler 60000-serien |
| `command` / `full_command` | Output från ett kommando | Du skriver regler |

Efter ändring i `ossec.conf` måste agenten startas om:

```bash
sudo systemctl restart wazuh-agent
```

Agenten tail:ar filerna — den läser bara nya rader, inte hela filen vid
omstart. Logrotate hanteras automatiskt (agenten upptäcker när filen
"krymper" och börjar om från början).

---

## Del 4 — Felsöka en agent som inte syns i managern

Vanlig SOC-uppgift: en kollega säger "min agent visar inte i Wazuh".
Här är felsökningskedjan oavsett om agenten kör på en vanlig server
eller i en container.

### Steg 1 — Kör agenten över huvud taget?

```bash
sudo /var/ossec/bin/wazuh-control status
# eller i Docker:
docker compose exec <service> /var/ossec/bin/wazuh-control status
```

Alla 5 daemoner ska vara `running`.

### Steg 2 — Hittar agenten managern?

```bash
getent hosts manager.example.com
# eller i Docker:
docker compose exec <service> getent hosts wazuh.manager
```

Ska returnera en IP. Annars är DNS / docker-nätverk fel.

### Steg 3 — Kan agenten nå managern på port 1514?

```bash
bash -c 'cat < /dev/tcp/manager.example.com/1514 &
         sleep 1; jobs -l'
```

Annars är firewall, nätverkssegmentering, eller managern-stoppad.

### Steg 4 — Lyckades enrollment?

Titta i agent-loggen:

```bash
sudo tail -30 /var/ossec/logs/ossec.log
```

Sök efter `"Successfully connected to server"` eller felmeddelanden.
Två vanliga:

- `"Duplicate name"` — managern vägrar för att en agent med samma namn
  finns sedan tidigare. Lösning: ta bort den gamla via API:n, eller
  konfigurera managern med `<force><enabled>yes</enabled></force>`
- `"Unable to connect"` — managern är inte nåbar (gå tillbaka till steg
  2 och 3)

---

## Del 5 — I Docker

Här finns flera strategier. Vi använder tre av dem i vårt repo.

### 5a. Två filer styr en container — vad gör vad?

Det finns en återkommande förvirring kring detta:

| Fil | Vad den säger | Per |
|---|---|---|
| **`docker-compose.yml`** (i repots rot) | Vilka services som finns, vilka portar de exponerar, vilka volymer, vilka beroenden mellan dem | Hela stacken |
| **`Dockerfile`** (i varje service-mapp) | Hur den enskilda imagen byggs — vilken base, vilka paket, vilket entrypoint | Per service |

I vårt repo:

```
docker-compose.yml          ← styr hela stacken
offer-ssh/
  Dockerfile                ← bygger logghantering/offer-ssh:4.14.4
  entrypoint.sh
  localfile-additions.xml
offer-juice-shop/
  Dockerfile                ← bygger logghantering/offer-juice-shop:4.14.4
  ...
nginx-proxy/
  Dockerfile                ← bygger logghantering/nginx-proxy:4.14.4
  ...
```

I `docker-compose.yml` står (förenklat):

```yaml
services:
  offer-ssh:
    build: ./offer-ssh             # bygg från Dockerfile i denna mapp
    image: logghantering/offer-ssh:4.14.4
    hostname: offer-ssh
    ports:
      - "2222:22"
    depends_on:
      - wazuh.manager
```

Compose-filen säger alltså bara *vilken Dockerfile* och *hur servicen
exponeras*. **Det är Dockerfile som faktiskt installerar Wazuh-agenten.**

I de tre första strategierna nedan är det Dockerfile som är intressant.
I strategi D är det docker-compose.yml.

### 5b. Strategi A — agent i din egen Dockerfile

**När:** du kontrollerar base-imagen och den har `apt`/`yum`-stöd.

**Exempel ur repot:** `offer-ssh/Dockerfile`, `nginx-proxy/Dockerfile`,
`flog-noise/Dockerfile` (sista stage).

**Dockerfile (förkortad):**

```dockerfile
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg openssh-server rsyslog \
    && rm -rf /var/lib/apt/lists/*

# Wazuh-agent
RUN curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
        | gpg --no-default-keyring \
              --keyring /usr/share/keyrings/wazuh.gpg --import \
    && chmod 644 /usr/share/keyrings/wazuh.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
       https://packages.wazuh.com/4.x/apt/ stable main" \
        > /etc/apt/sources.list.d/wazuh.list \
    && apt-get update \
    && WAZUH_MANAGER='wazuh.manager' \
       apt-get install -y --no-install-recommends wazuh-agent=4.14.4-1 \
    && rm -rf /var/lib/apt/lists/*
```

**docker-compose.yml:**

```yaml
services:
  offer-ssh:
    build: ./offer-ssh
    image: logghantering/offer-ssh:4.14.4
    hostname: offer-ssh
    ports:
      - "2222:22"
    depends_on:
      - wazuh.manager
```

Notera **`WAZUH_MANAGER='wazuh.manager'`** i Dockerfile — det är hostname
agenten ska kontakta. Det måste matcha service-namnet på manager-containern
i `docker-compose.yml` (i vårt fall `wazuh.manager`).

**För/nackdelar:**
- Enkelt, en container, allt i samma
- Agenten ser samma filsystem som appen → kan göra FIM på app-filer
- Image-storleken ökar med ~150 MB
- Funkar inte om base-imagen saknar `apt`/`yum`

### 5c. Strategi B — multi-stage med "donor"-image

**När:** den officiella imagen av din app är minimal (distroless, scratch)
— du kan inte installera saker i den, så du måste *kopiera ut appen* till
en miljö där agenten passar.

**Exempel ur repot:** `offer-juice-shop/Dockerfile`

Juice Shops officiella image (`bkimminich/juice-shop:v17.3.0`) är
distroless — den har ingen `sh`, inga apt-tools. Lösning: två stages.

**Dockerfile:**

```dockerfile
# Stage 1: "donor" — hämta appen från den officiella imagen
FROM bkimminich/juice-shop:v17.3.0 AS juice

# Stage 2: vår egen miljö med agent
FROM debian:bookworm-slim
# ... wazuh-agent install som i strategi A ...

# Kopiera in appen från donor-imagen
COPY --from=juice /juice-shop /juice-shop
COPY --from=juice /nodejs /nodejs

CMD ["/entrypoint.sh"]
```

**docker-compose.yml:** ser likadan ut som strategi A — compose vet inte
att Dockerfile har två stages, det är en byggdetalj.

**För/nackdelar:**
- Funkar oavsett base-image för app
- App-versionen är pinnad (`v17.3.0`)
- Mer komplex Dockerfile
- Du tar ansvar för säkerhetsuppdateringar av app-koden

### 5d. Strategi C — multi-stage builder (verktyg från källkod)

**När:** ditt verktyg saknas som färdig image för din arkitektur, eller
du vill bygga från källkod för transparens/säkerhet.

**Exempel ur repot:** `flog-noise/Dockerfile`

mingrammer/flog finns bara som amd64-image. Vi behöver arm64 (Mac).
Lösning: bygg från källkod.

**Dockerfile:**

```dockerfile
FROM golang:1.22-bookworm AS builder

RUN git clone --depth 1 --branch v0.4.3 \
    https://github.com/mingrammer/flog.git /src \
    && cd /src \
    && go build -o /flog

FROM debian:bookworm-slim
# ... wazuh-agent install ...
COPY --from=builder /flog /usr/local/bin/flog
```

Vi pinnar `v0.4.3` av flog. Reproducerbart även om upstream pushar nya
versioner.

### 5e. Strategi D — sidecar (separat agent-container)

**När:** du vill inte modifiera app-containern alls (t.ex. om den är
tredjepart eller låst).

Här är **docker-compose.yml** det viktiga (inte Dockerfile):

```yaml
services:
  app:
    image: someones/app:latest          # OBS: orörd, du modifierar inte
    volumes:
      - applogs:/var/log/app

  wazuh-agent:
    image: wazuh/wazuh-agent:4.14.4     # officiell agent-image
    hostname: app-host
    environment:
      - WAZUH_MANAGER=wazuh.manager
    volumes:
      - applogs:/var/log/app:ro         # läser app:ens loggar
```

Båda containrarna delar en volym där app:en skriver loggar och agenten
läser dem.

**För/nackdelar:**
- App-container helt orörd
- Bra om appen är låst tredjepart
- Agenten ser bara *filer*, inte *processer* eller *nätverk* i app-
  containern → mindre FIM, ingen SCA-skanning på app:ens host
- Två containers per "endpoint" — fler resurser

Vi använder inte denna strategi i kursen, men det är värt att känna till
— det är det vanligaste sättet i Kubernetes.

### 5f. Variationer per base-image

| Base-image | Strategi A fungerar? | Notering |
|---|---|---|
| `debian:*`, `ubuntu:*` | Ja | apt + glibc. Vad vi gör i repot. |
| `rockylinux:*`, `almalinux:*`, `fedora:*` | Ja | Använd yum/dnf — ändra Dockerfile |
| `alpine:*` | **Nej** | Alpine kör **musl libc**, Wazuh-agenten kräver **glibc**. Använd debian-bas eller sidecar. |
| `distroless/*` | Nej | Ingen package manager. Använd strategi B (multi-stage). |
| `scratch` | Nej | Tom image. Använd strategi B. |
| `mcr.microsoft.com/windows/*` | Annat | Wazuh har separat Windows-installer (MSI). |

Alpine-fallet är *särskilt värt* att känna till. Många containers
(`redis:7-alpine`, `nginx:alpine`, `python:3.12-alpine`) använder
Alpine för minimal storlek — men där fungerar inte strategi A. Du måste
gå till strategi D (sidecar) eller byta till en glibc-baserad variant
(`redis:7-bookworm`, `nginx:bookworm`, `python:3.12-slim`).

---

## Del 6 — Pedagogisk reflexion: agent ≠ värde

I vårt repo har vi installerat Wazuh-agent i fyra olika offer-containrar:
`offer-ssh`, `offer-juice-shop`, `nginx-proxy`, `flog-noise`. Den
fungerar tekniskt i alla fyra — men de fyller *fyra helt olika roller*:

| Container | Vad agenten "ser" | Roll i labbmiljön |
|---|---|---|
| `offer-ssh` | auth.log + syslog | **Target (klassiskt)** — failed/successful logins, klassisk SOC-data |
| `nginx-proxy` | nginx access.log (apache-format) | **Target (modernt)** — web-attacker triggar 31100-serien |
| `flog-noise` | flog-genererade loggar i 3 format | **Bakgrundsbrus** — *medvetet* lågt signal-värde; ska göra miljön "levande" så riktiga attacker syns *i kontrast* |
| `offer-juice-shop` | bara default SCA-skanning av sin host | **Pedagogiskt anti-exempel** — agenten är installerad och kör, men ger inget värde pga loggformat |

### Juice-shop-fallet är värt att fundera på

Vi installerade agenten i `offer-juice-shop`. Den registrerar sig fint
mot managern, status är `active`, allt ser bra ut.

**Men i praktiken gör den nästan inget värdefullt.** Juice Shop loggar
på stdout i ett Node.js Express-format som inte matchar någon av Wazuhs
default-decoders. Agenten *läser* loggarna, *skickar* dem till managern,
men managern vet inte vad den ska göra med dem.

Det enda agenten i juice-shop-containern bidrar med är SCA-skanning av
sin egen debian-host — samma som vilken annan debian-baserad container
som helst.

**Det är just därför vi byggde `nginx-foran-juice-shop`-branchen.** nginx
producerar Combined Log Format som Wazuh kan, så när agenten i
*nginx*-containern läser den loggen så triggar alla våra SQL injection-,
XSS- och path traversal-mönster vettiga regler.

**Lärdom:**

> Att installera en Wazuh-agent är **en** del av lösningen. Att se till
> att den läser *rätt loggar*, i ett *format som har decoder-stöd*, är
> resten. Annars är agenten en dyr SCA-skanner.

### Framtidsblick: DVWA blir kontrasten

I en framtida branch lägger vi till DVWA (Damn Vulnerable Web Application
— en klassisk, avsiktligt sårbar PHP-app från ~2010, ofta använd som
standard-target i webbsäkerhetskurser). Det är en *PHP-applikation som
körs ovanpå Apache* — alltså en *traditionell* arkitektur där webservern
och appen är separerade. DVWA skriver redan Combined Log Format till
`/var/log/apache2/access.log`.

För DVWA behöver vi **inte** någon nginx-proxy. Det räcker att:
1. Installera Wazuh-agent (strategi A)
2. Lägga till en `<localfile log_format="apache">` för Apaches access.log

Det visar att *moderna SPA-arkitekturer* (Single Page Application — React/Node-backend som Juice Shop)
ofta kräver mer eftertanke kring loggning än *klassiska arkitekturer*
(PHP/Apache som DVWA). Det är inget fel i sig — det är bara verklighet
för SOC-yrket.

---

## Frivillig bonus-uppgift

Bygg en egen container med Wazuh-agent inuti och få den att registrera
sig mot managern. Du har två svårighetsgrader:

### Spår A — Lätt (Ubuntu)

Bygg en `ubuntu:24.04`-baserad container med en enkel tjänst som loggar
(t.ex. `cron` som kör `date >> /var/log/heartbeat.log` varje minut).
Installera Wazuh-agent. Verifiera att den syns i dashboarden.

Tips: kopiera `offer-ssh/Dockerfile` som mall och ändra `FROM`-raden.

### Spår B — Utmaning (Alpine)

Försök samma sak med `alpine:3.20`. Vad händer? Dokumentera vad som
strular. När du gett upp — vilken strategi från artikeln skulle du
välja istället, och varför?

Du kommer stöta på problem. **Det är poängen.** Det är inte misslyckande
att Alpine inte fungerar — det är en realitet i SOC-yrket att inte alla
endpoints kan ha agent inuti. Den som dokumenterar varför Alpine inte
funkar har lärt sig mer än den som bara klistrar in ubuntu.

Tog du B-spåret? Ta med dina anteckningar till onsdag — vi diskuterar
gärna vad du stötte på.

---

## Sammanfattning

| När du... | Använd... |
|---|---|
| Sätter upp en vanlig Linux-server | Manuell installation (Del 2) |
| Bygger egen container med kontroll över base-image | Strategi A (Dockerfile + apt) |
| Använder en distroless/minimal officiell image | Strategi B (multi-stage donor) |
| Behöver bygga ett verktyg från källkod | Strategi C (multi-stage builder) |
| Får inte modifiera app-containern | Strategi D (sidecar via docker-compose) |
| Kör Alpine | Byt base, eller använd sidecar |

Alla våra fyra Dockerfiler (`offer-ssh/`, `offer-juice-shop/`,
`nginx-proxy/`, `flog-noise/`) följer strategi A eller B. Studera dem —
varje en är ett konkret arbetsexempel.
