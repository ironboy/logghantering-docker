## Logghantering — labbmiljö (ITS25)

Det repo vi ska använda innehåller labbmiljön för kursen Logghantering, playbooks och forensisk bevisinsamling.

https://github.com/ironboy/logghantering-docker/tree/nginx-foran-juice-shop

**Obs!** Denna branch — **nginx-foran-juice-shop** — bygger ovanpå `juice-shop` och lägger en **nginx reverse proxy** framför Juice Shop. nginx access-loggen läses av Wazuh-agenten — och nu triggar klassiska web-attacker (SQL injection, path traversal, XSS) verkliga alerts i Wazuh. Se [README-nginx-attacks.md](./README-nginx-attacks.md) för exempel.

Miljön körs med Docker Compose och bygger på

[Wazuh](https://wazuh.com) 4.14.4 i single-node-läge.

Du behöver bara kunna köra två-tre kommandon för att komma igång.

---

## 1. Förutsättningar

Innan du börjar, säkerställ att din maskin uppfyller följande:

| Krav | Detalj |
|------|--------|
| **Docker Desktop** | Senaste versionen, installerad och igång |
| **RAM tilldelat Docker** | Minst **4 GB**, helst 6 GB |
| **Diskutrymme** | Minst 10 GB ledigt |
| **Internet** | Krävs första gången (för att ladda ned ~3 GB images) |
| **Admin-rättigheter** | Krävs för Windows-pillet i steg 3 nedan |

Du behöver **inte** ha installerat Wazuh, OpenSearch eller Java på din maskin.
Allt körs inne i containrar.

---

## 2. Hämta zip-fil av repot

Hämta zippen för denna branch:

https://github.com/ironboy/logghantering-docker/archive/refs/heads/nginx-foran-juice-shop.zip

Packa upp den och stå dig i projektets rot (där `docker-compose.yml` ligger).
**Resten av kommandona i denna README körs från projektets rot** om inget annat sägs.

### Compose-strukturen

I projektets **rot** finns en `docker-compose.yml`. Det är **alltid den du
kör** — du behöver inte gå in i underkataloger för att starta saker. Den filen
kan i sin tur inkludera andra `docker-compose.yml`-filer (t.ex.
`wazuh/docker-compose.yml`) och bygga ovanpå dem, men det sköts automatiskt
av Docker Compose.

Tumregel: stå i projektets rot, kör `docker compose up -d`. Klart.

---

## 3. Plattformsspecifik förberedelse — `vm.max_map_count`

Wazuh använder OpenSearch som söker-/lagringsmotor. OpenSearch kräver att
Linux-kerneln har `vm.max_map_count` satt till minst **262144**. Hur du sätter
det beror på vilket operativsystem du kör Docker på.

> **Symptom om det är fel:** Wazuh-indexern startar och kraschar direkt med
> felmeddelandet `max virtual memory areas vm.max_map_count [65530] is too low`.

### 3a. Windows (med WSL2-backend) — **alla Windows-studenter**

Docker Desktop på Windows kör i en Linux-VM via WSL2. Du måste sätta värdet i
WSL2:s konfiguration.

Skapa eller öppna filen `%USERPROFILE%\.wslconfig` (t.ex.
`C:\Users\dittnamn\.wslconfig`) och lägg till:

```ini
[wsl2]
kernelCommandLine = sysctl.vm.max_map_count=262144
```

Spara filen, öppna sedan PowerShell **som administratör** och kör:

```powershell
wsl --shutdown
```

Starta sedan Docker Desktop igen. Värdet är nu permanent — du behöver inte göra
om detta vid varje start.

**Verifiera** att det fungerar genom att i en terminal köra:

```bash
docker run --rm busybox sysctl vm.max_map_count
```

Förväntat svar: `vm.max_map_count = 262144`.

### 3b. macOS

Docker Desktop på Mac har som regel redan rätt värde satt i sin interna VM
(sedan ~Docker Desktop v4.x). **Du behöver troligen inte göra något.**

Verifiera med samma kommando som ovan:

```bash
docker run --rm busybox sysctl vm.max_map_count
```

Om värdet redan är ≥ 262144 är du klar. Om det är lägre, uppgradera Docker
Desktop till senaste versionen.

### 3c. Linux (native, utan Docker Desktop)

Sätt värdet på din host:

```bash
sudo sysctl -w vm.max_map_count=262144
```

Gör det permanent genom att lägga till följande rad i `/etc/sysctl.conf`:

```
vm.max_map_count=262144
```

---

## 4. Generera certifikat (en gång)

Wazuh använder TLS-certifikat internt mellan manager, indexer och dashboard. Vi
genererar dem med ett medföljande verktyg.

```bash
docker compose -f wazuh/generate-indexer-certs.yml run --rm generator
```

Detta körs **en gång** vid första uppsättningen. Certifikaten hamnar i
`wazuh/config/wazuh_indexer_ssl_certs/` och återanvänds vid varje start.

---

## 5. Starta labbmiljön

```bash
docker compose up -d
```

Första gången laddar Docker ned ~3 GB images. Räkna med 5–10 minuter beroende
på din internetuppkoppling.

Efter att images är nedladdade tar miljön ytterligare cirka **1 minut** att
komma igång — Wazuh-indexern måste skapa sina interna index vid första start.

Kontrollera att alla containrar är `Up`:

```bash
docker compose ps
```

Du ska se sex rader: `wazuh.manager`, `wazuh.indexer`, `wazuh.dashboard`,
`offer-ssh`, `offer-juice-shop` och `nginx-proxy` — samtliga med status `Up`.

---

## 6. Logga in på dashboarden

Öppna webbläsaren och gå till:

```
https://localhost
```

Webbläsaren kommer varna för **självsignerat certifikat** — det är förväntat i
en labbmiljö. I Chrome/Edge: klicka "Avancerat" → "Fortsätt till localhost".
I Firefox: "Avancerat" → "Acceptera risken".

Logga in med:

- **Användare:** `admin`
- **Lösenord:** `SecretPassword`

> Detta är **default-lösenord**. I en produktionsmiljö är första steget att
> byta dem. Vi behåller defaults i lab-miljön för enkelhetens skull — men
> notera att det aldrig är ok i skarp drift.

---

## 7. Offer-containrar

Denna branch innehåller två "offer" — bait-servers som genererar loggar för
Wazuh att samla in. Varje offer kör Wazuh-agent 4.14.4 inuti containern och
registrerar sig automatiskt mot managern.

### 7a. `offer-ssh` — debian + SSH-server

- **Bas:** `debian:bookworm-slim` med `openssh-server`, `rsyslog` och
  Wazuh-agent förinstallerade
- **SSH-port:** `2222` på din host (mappar till port `22` i containern)
- **Lab-användare:**
  - `student` med lösenord `lab` (vanlig user)
  - `root` med lösenord `lab` (root-inloggning är aktiverad — intentionellt
    svagt för pedagogik)

**Testa:**

```bash
ssh -p 2222 student@localhost
# lösenord: lab
```

Misslyckade och lyckade inloggningar dyker upp i Wazuh-dashboarden under
**Threat Hunting** → filtrera på `agent.name: offer-ssh`.

### 7b. `offer-juice-shop` — OWASP Juice Shop (bakom nginx-proxy)

[OWASP Juice Shop](https://owasp.org/www-project-juice-shop/) är en avsiktligt
sårbar Node.js-webapp som täcker hela OWASP Top 10. Den används flitigt i
webbsäkerhetskurser — du kanske känner igen den.

- **Bas:** `debian:bookworm-slim` med Wazuh-agent + Juice Shop v17.3.0 (kopierad
  från `bkimminich/juice-shop:v17.3.0`)
- **Intern port:** `3000` (inte exponerad mot host i denna branch)

På denna branch når du Juice Shop **via nginx-proxy**, inte direkt — se §7c.

### 7c. `nginx-proxy` — reverse proxy framför Juice Shop

- **Bas:** `debian:bookworm-slim` med `nginx`, `rsyslog` och Wazuh-agent
- **Webb-port:** `3000` på din host (mappar till port `80` i containern)
- **Roll:** tar emot all webb-trafik och proxar den till `offer-juice-shop:3000`
  internt. Loggar varje request till `/var/log/nginx/access.log` i Combined
  Log Format — det Wazuh känner igen out-of-the-box.

**Testa:**

```
http://localhost:3000
```

Detta ser exakt ut som Juice Shop direkt — men nu finns nginx i mitten, och
varje request blir en loggrad som Wazuhs `web-accesslog`-decoder läser.

**Web-attacker som SIEM:en nu ser:**
SQL injection, path traversal, reflected XSS, scanner-beteende m.fl. Se
[README-nginx-attacks.md](./README-nginx-attacks.md) för konkreta
exempel-attacker att köra mot stacken — och vilka Wazuh-regler som triggas.

> Alla offer-containrar är medvetet osäkert konfigurerade. De är till för att
> vi ska kunna SE attacker mot dem i loggarna — kör dem **bara lokalt**,
> exponera dem aldrig mot internet.

---

## 8. Stoppa labbmiljön

När du är klar för dagen:

```bash
docker compose stop
```

Detta stoppar containrarna men sparar all data i Docker-volymer. Nästa gång
startar du med:

```bash
docker compose start
```

Om du vill **nollställa allt** (radera alla index, alla loggar, alla agenter):

```bash
docker compose down -v
```

Du behöver då även regenerera certifikat (steg 4) innan du startar om.

---

## 9. Troubleshooting

### "max virtual memory areas vm.max_map_count [65530] is too low"

Du har inte gjort steg 3 korrekt, eller WSL2 har inte läst om sin konfiguration.

- Windows: kontrollera `%USERPROFILE%\.wslconfig`, kör `wsl --shutdown`, starta Docker Desktop på nytt.
- Verifiera med `docker run --rm busybox sysctl vm.max_map_count`.

### Cert-genereringen failar med "Operation not permitted"

Vanligast på Windows: zippen är upppackad på `C:\` (NTFS) i stället för i
WSL2:s eget filsystem. Flytta projektmappen till `~/` inne i WSL2 och försök
igen.

### Dashboarden svarar inte på `https://localhost`

Vänta minst 1 minut efter `docker compose up -d`. Om problemet kvarstår:

```bash
docker compose logs wazuh.indexer | tail -50
docker compose logs wazuh.dashboard | tail -50
```

Vanligaste fel: indexern har inte hunnit starta klart. Vänta ytterligare en minut.

### Containers crashar med "out of memory"

Höj minnet som Docker Desktop får använda:
- Docker Desktop → Settings → Resources → Memory → minst 6 GB.

### Port 443 / 9200 / 1514 / 2222 / 3000 redan upptagen

Något annat program använder porten. På macOS/Linux:

```bash
lsof -i :443
```

Stoppa programmet eller ändra port-mappningen i `docker-compose.yml`.

### "Couldn't connect to Docker daemon"

Docker Desktop är inte igång. Starta det manuellt och försök igen.

---

## 10. Vanliga kommandon (för uppslag)

| Vad | Kommando |
|-----|----------|
| Starta i bakgrund | `docker compose up -d` |
| Stoppa | `docker compose stop` |
| Starta efter stop | `docker compose start` |
| Visa status | `docker compose ps` |
| Visa loggar | `docker compose logs -f <service>` |
| Stoppa + radera volymer | `docker compose down -v` |
| Gå in i en container | `docker compose exec <service> bash` |
| SSH:a till offer-ssh | `ssh -p 2222 student@localhost` |
| Öppna Juice Shop (via nginx) | `http://localhost:3000` |

Service-namn i denna miljö: `wazuh.manager`, `wazuh.indexer`, `wazuh.dashboard`, `offer-ssh`, `offer-juice-shop`, `nginx-proxy`.

---

## 11. Vad händer härnäst?

Detta repo kommer växa under kursens gång, med fler **branches**. Nya
containrar för loggkällor och attackscenarier läggs till stegvis — din lärare
kommer att meddela när det är dags att hämta en ny version/branch.
