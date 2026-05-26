# Forensik: bevishantering, hashning och chain of custody

Den här artikeln är ett praktiskt komplement till veckans läsning (ENISA:s
*Electronic evidence: a basic guide for First Responders* och NIST SP
800-86). Läsningen ger principerna — här visar vi konkret *hur* man gör,
med kommandon du kan köra direkt i din egen labbmiljö.

Allt nedan kopplar direkt till din inlämningsuppgift: **Del A4
(inneslutning + bevarande av bevis)** och **Bilaga 1 (loggutdrag med
hashar)**.

---

## Varför forensik skiljer sig från "vanlig" logganalys

När du analyserar loggar för att *förstå* en incident räcker det att titta.
Men om utredningen kan leda till åtgärder mot en person — uppsägning,
polisanmälan, myndighetsrapport — måste bevisen vara **hållbara**. Det
betyder att du måste kunna visa:

1. **Var** beviset kom ifrån
2. **När** det samlades in
3. Att det **inte ändrats** sedan dess
4. **Vem** som hanterat det, hela vägen

Kan du inte visa det, kan beviset avfärdas. Det är hela poängen med
*chain of custody* (beviskedja).

---

## De fyra faserna (NIST SP 800-86)

NIST delar in den forensiska processen i fyra steg:

| Fas | Vad du gör |
|-----|-----------|
| **Collection** | Samla in data — identifiera, säkra och kopiera källorna |
| **Examination** | Bearbeta insamlad data — extrahera det relevanta ur stora mängder |
| **Analysis** | Dra slutsatser — vad hände, i vilken ordning, av vem |
| **Reporting** | Dokumentera — så att någon annan kan följa och lita på din slutsats |

Faserna hänger ihop med rapportdelarna ungefär så här:

- **Collection** (säkra och kopiera bevis) → **Del A4**
- **Examination** (köra queries, extrahera relevanta events ur loggarna) → **Del A3**
- **Analysis** (vad hände, rotorsak) → **Del A3** (slutsats) och **Del A7** (rotorsaksanalys)
- **Reporting** → hela dokumentet

Notera att NIST:s forensik-faser inte är samma sak som SANS
incident-faser (som Del A följer) — de överlappar men kartlägger inte
ett-till-ett.

---

## Kärnan: integritet genom hashning

En **hash** är ett slags digitalt fingeravtryck av en fil. En
hash-funktion (vi använder **SHA-256**) tar en fil av valfri storlek och
ger en sträng på exakt 64 tecken. Två egenskaper gör den användbar för
forensik:

- **Deterministisk** — samma fil ger *alltid* samma hash
- **Lavineffekt** — minsta ändring ger en *helt annan* hash

### Konkret demonstration

Skapa en fil och hasha den (Linux/WSL — det de flesta av er kör):

```
$ sha256sum bevis-demo.txt
19a0663d05f9767f0fefed5a27a622ffcbb692f142fcfd9e92dd266ea990d8d9  bevis-demo.txt
```

Kör samma kommando igen — **identisk hash** (filen är oförändrad):

```
$ sha256sum bevis-demo.txt
19a0663d05f9767f0fefed5a27a622ffcbb692f142fcfd9e92dd266ea990d8d9  bevis-demo.txt
```

Ändra nu **en enda tecken** i filen (`10.0.0.5` → `10.0.0.6`) och hasha
igen:

```
$ sha256sum bevis-demo.txt
aa6ffd5237a7803cd7794ef6dbabef863f5585c6c6fbf1ae59491767868e4509  bevis-demo.txt
```

Helt annan hash. Det är *därför* hashen är ett bevis på att en fil inte
ändrats: om du hashade en logg vid insamlingen och hashen är densamma
veckor senare, så vet du att ingen rört den.

### Kommandon per plattform

| Plattform | Kommando |
|-----------|----------|
| **Linux / WSL** | `sha256sum fil.log` |
| **Inuti en Docker-container** | `docker exec <container> sha256sum /sökväg/fil.log` |
| **macOS** | `shasum -a 256 fil.log` |
| **Windows (PowerShell, utan WSL)** | `Get-FileHash fil.log -Algorithm SHA256` |

Alla ger samma 64-teckens hash för samma fil — algoritmen är densamma
oavsett verktyg. Kör du Windows i den här kursen jobbar du i WSL, så
`sha256sum` är kommandot du använder.

---

## Extrahera bevis från labbmiljön

I din labb ligger loggarna inuti containrar. Forensiskt vill du **kopiera
ut** dem (arbeta aldrig på originalet) och sedan hasha kopian.

```bash
# 1. Kopiera ut loggen från containern
docker cp logghantering-docker-nginx-proxy-1:/var/log/nginx/access.log ./access-bevis.log

# 2. Hasha kopian
sha256sum ./access-bevis.log
```

Verkligt exempel från vår miljö:

```
$ docker cp ...nginx-proxy-1:/var/log/nginx/access.log ./access-bevis.log
$ sha256sum ./access-bevis.log
452deefcee672dd7abaa04c3f30267651d7ca5d91f27b8005bb9a4291ab96405  ./access-bevis.log
```

För att *bevisa* att kopian är trogen originalet — hasha även originalet
inuti containern och jämför:

```
$ docker exec ...nginx-proxy-1 sha256sum /var/log/nginx/access.log
452deefcee672dd7abaa04c3f30267651d7ca5d91f27b8005bb9a4291ab96405  /var/log/nginx/access.log
```

**Samma hash** = kopian är en exakt, oförändrad kopia av originalet. Det
är denna jämförelse du dokumenterar.

---

## Chain of custody — beviskedjan

Chain of custody är dokumentationen som följer ett bevis från insamling
till slutförvaring. För loggfiler i en SOC-utredning räcker en tabell.
Det här är exakt strukturen för **Bilaga 1** i din rapport:

| Filnamn | Källa | Insamlad (UTC) | SHA-256 | Lagringsplats | Insamlad av |
|---------|-------|----------------|---------|---------------|-------------|
| `access-bevis.log` | nginx-proxy-container, `/var/log/nginx/access.log` | 2026-05-26 05:03:33 | `452deef...ab96405` | `~/incident-2026-05/bevis/` + krypterad backup | Anna A. |
| `wazuh-alerts-export.json` | Wazuh-indexer, `wazuh-alerts-*` | 2026-05-26 05:10:11 | `9c3f...` | samma | Anna A. |

Några regler för tabellen:

- **Fullständig hash** (alla 64 tecken) — inte `452deef...` i den riktiga
  bilagan. Förkortningen här är bara för läsbarhet.
- **Tidpunkt i UTC** — undvik tidszonsförvirring. Logga alltid i UTC och
  notera det.
- **Lagringsplats** — var ligger filen nu, och finns en backup?

---

## Praktiska principer (från ENISA / NIST)

### 1. Arbeta alltid på en kopia

Rör aldrig originalet. Kopiera ut, hasha, och arbeta sedan på kopian. Om
du analyserar originalet riskerar du att ändra det (även att *öppna* en
fil kan ändra metadata som "senast använd").

### 2. Hasha vid insamling — och igen senare

Hashen vid insamlingstillfället är din baslinje. När som helst senare kan
du hasha om filen och visa att den är oförändrad. Spara baslinje-hashen
*separat* från filen (t.ex. i din chain of custody-tabell).

### 3. UTC, alltid

Tidsstämplar i loggar och i din dokumentation ska vara i UTC. Annars
uppstår frågor som "var det 14:00 svensk tid eller UTC?" — och i en
utredning är sådana oklarheter förödande.

### 4. Order of volatility (RFC 3227)

Samla in det mest flyktiga *först*. Data försvinner i denna ordning:

1. CPU-register, cache (försvinner direkt)
2. RAM / minnesinnehåll (försvinner vid avstängning)
3. Nätverksanslutningar, processer
4. Diskdata, loggfiler (relativt beständigt)
5. Backuper, arkiv (mest beständigt)

För vår kurs jobbar vi mest i lager 4 (loggfiler) — men principen är värd
att känna till: om du måste välja, säkra det flyktiga först.

### 5. Dokumentera allt du gör

Varje kommando du kör, varje fil du rör. Om du inte skrev ner det, hände
det inte (ur bevissynpunkt).

---

## Verktyg värda att känna till

- **`shasum` / `sha256sum` / `Get-FileHash`** — hashning (det du behöver
  för kursen)
- **`dd`** — bit-för-bit-kopiering av hela diskar/partitioner (tyngre
  forensik)
- **Autopsy / The Sleuth Kit** — grafiska forensik-suiter för
  diskanalys
- **Wazuh själv** — exportera alerts/arkiv som JSON-bevis direkt från
  indexern

För loggbaserad SOC-forensik (vår nivå) räcker hash-verktygen + en
ordentlig chain of custody-tabell långt.

---

## Inför din rapport

Övningen till denna lektion var att lista dina egna bevis. Använd
strukturen ovan:

1. Vilka filer extraherade du under din utredning?
2. När (UTC)?
3. SHA-256 för varje?
4. Var lagras de?

Det blir direkt råmaterial till **Bilaga 1** och **Del A4**. Ta med din
lista på lektionen så fyller vi i luckorna tillsammans.
