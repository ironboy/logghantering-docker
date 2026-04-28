# Logghantering — labbmiljö (ITS25)

Det repo vi ska använda innehåller labbmiljön för kursen Logghantering, playbooks och forensisk bevisinsamling.

https://github.com/ironboy/logghantering-docker/tree/wazuh-only

**Obs!** Initialt denna branch **wazuh only**.

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

## 2. Hämta zip-fil av repot (du kan skapa ditt eget repo utifrån denna)

Börja med denna branch, **wazuh-only**, vi bygger på med andra med fler containrar efterhand:

```
https://github.com/ironboy/logghantering-docker/archive/refs/heads/wazuh-only.zip
```

Resten av kommandona i denna README körs från `wazuh/`-mappen om inget annat sägs.

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
docker compose -f generate-indexer-certs.yml run --rm generator
```

Detta körs **en gång** vid första uppsättningen. Certifikaten hamnar i
`config/wazuh_indexer_ssl_certs/` och återanvänds vid varje start.

---

## 5. Starta labbmiljön

```bash
docker compose up -d
```

Första gången laddar Docker ned ~3 GB images. Räkna med 5–10 minuter beroende
på din internetuppkoppling.

Efter att images är nedladdade tar miljön ytterligare cirka **1 minut** att
komma igång — Wazuh-indexern måste skapa sina interna index vid första start.

Kontrollera att alla tre containrar är `Up`:

```bash
docker compose ps
```

Du ska se tre rader: `wazuh.manager`, `wazuh.indexer`, `wazuh.dashboard` —
samtliga med status `Up`.

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

## 7. Stoppa labbmiljön

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

## 8. Troubleshooting

### "max virtual memory areas vm.max_map_count [65530] is too low"

Du har inte gjort steg 3 korrekt, eller WSL2 har inte läst om sin konfiguration.

- Windows: kontrollera `%USERPROFILE%\.wslconfig`, kör `wsl --shutdown`, starta Docker Desktop på nytt.
- Verifiera med `docker run --rm busybox sysctl vm.max_map_count`.

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

### Port 443 / 9200 / 1514 redan upptagen

Något annat program använder porten. På macOS/Linux:

```bash
lsof -i :443
```

Stoppa programmet eller ändra port-mappningen i `docker-compose.yml`.

### "Couldn't connect to Docker daemon"

Docker Desktop är inte igång. Starta det manuellt och försök igen.

---

## 9. Vanliga kommandon (för uppslag)

| Vad | Kommando |
|-----|----------|
| Starta i bakgrund | `docker compose up -d` |
| Stoppa | `docker compose stop` |
| Starta efter stop | `docker compose start` |
| Visa status | `docker compose ps` |
| Visa loggar | `docker compose logs -f <service>` |
| Stoppa + radera volymer | `docker compose down -v` |
| Gå in i en container | `docker compose exec <service> bash` |

Service-namn i denna miljö: `wazuh.manager`, `wazuh.indexer`, `wazuh.dashboard`.

---

## 10. Vad händer härnäst?

Detta repo kommer växa under kursens gång, med fler **branches**. Nya containrar för loggkällor och
attackscenarier läggs till stegvis — du behöver bara köra `git pull` och sedan
`docker compose up -d` för att få med nya delar.
