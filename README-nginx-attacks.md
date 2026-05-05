## Web-attacker mot Juice Shop — och hur Wazuh ser dem

Denna branch (`nginx-foran-juice-shop`) har lagt en **nginx reverse proxy**
framför Juice Shop. Det betyder att all HTTP-trafik passerar genom nginx, som
loggar varje request i Combined Log Format till `/var/log/nginx/access.log`.

Wazuh-agenten inne i nginx-containern läser den filen, och Wazuhs inbyggda
**web-accesslog**-decoder + regler 31100-serien känner igen klassiska attack-
mönster i URL:er: SQL injection, XSS, path traversal, scanner-beteende.

Det här är poängen: **rätt loggar på rätt plats = SIEM:en ser attackerna.**

---

### Förutsättningar

Stacken körs (`docker compose up -d` i projektets rot). Juice Shop nås på
`http://localhost:3000` (nu via nginx, inte direkt till Node.js).

Wazuh-dashboarden: `https://localhost`. Logga in med `admin` /
`SecretPassword`.

---

### Vad du letar efter i dashboarden

I Threat Hunting, sök:

```
agent.name: "nginx-proxy" AND decoder.name: "web-accesslog"
```

Här hamnar **alla** alerts som triggas av web-trafik. Före du kör attackerna
nedan ska den vyn vara nästan tom (möjligen någon `31122` "500-error" från
juice-shop's egen interna pipeline). Efter attackerna ska du se nya alerts
flöda in inom någon minut.

---

### Attack 1 — SQL injection i URL

Juice Shop's REST-API har ett produktsök på `/rest/products/search?q=`. Vi
försöker mata in en klassisk UNION SELECT-payload:

```bash
curl "http://localhost:3000/rest/products/search?q=apple%27%20UNION%20SELECT%20%2A%20FROM%20users--"
```

(Det är `apple' UNION SELECT * FROM users--` URL-encoded.)

**Förväntat utfall:**
- Juice Shop returnerar HTTP 500 (intern server-error — den försöker köra SQL
  och kraschar)
- Wazuh triggar **rule 31103 — "SQL injection attempt"** (severity 7)
- Bonus: **rule 31122 — "Web server 500 error code"** triggas också

I Threat Hunting hittar du den med:

```
rule.id: 31103 OR rule.id: 31164
```

Pedagogisk poäng: detta är just det Juice Shop's "Login Admin" / "Christmas
Special"-utmaningar handlar om i [pwning-guiden][1]. Där angriper man
applikationen via UI:t. Här ser vi *infrastruktur-perspektivet* — hur
attacken syns i en SIEM som lyssnar på rätt loggar.

---

### Attack 2 — Path traversal (LFI-försök)

Klassiskt mönster: kan vi använda `../../etc/passwd` i URL:n för att läsa
filer utanför webroot? Med URL-encoding undviker vi att curl/nginx
normaliserar bort `../`:

```bash
curl "http://localhost:3000/%2e%2e/%2e%2e/%2e%2e/etc/passwd"
```

**Förväntat utfall:**
- nginx returnerar HTTP 400 (Bad Request — den tycker URL:n är konstig)
- Wazuh triggar **rule 31104 — "Common web attack"** (severity 6)

Sökning:

```
rule.id: 31104
```

Pedagogisk poäng: även om attacken **misslyckas** (status 400, ingen fil
läckte) så *upptäckte SIEM:en mönstret*. Det är lika viktigt — i en riktig
SOC vill du veta vem som *försöker*, inte bara vem som *lyckas*. Det är
ofta första steget i en kedja.

---

### Attack 3 — Reflected XSS i URL

Skickar in en `<script>`-tag som query-parameter:

```bash
curl "http://localhost:3000/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
```

(Det är `<script>alert(1)</script>` URL-encoded.)

**Förväntat utfall:**
- Juice Shop returnerar HTTP 200 (servern tar emot den, men den lyckas inte
  reflektera XSS:en på den här endpointen — i en sårbar app skulle skriptet
  exekverats i klientens browser)
- Wazuh triggar **rule 31106 — "A web attack returned code 200 (success)"**
  (severity 6)

Sökning:

```
rule.id: 31106
```

Pedagogisk poäng: rule 31106 är **särskilt intressant** för en SOC-analytiker
— "ett attack-mönster fick svar 200 från servern". Det betyder att servern
inte avvisade requesten. Det betyder *inte* automatiskt att attacken lyckades,
men det är en signal om att fördjupa sin analys.

---

### Bonus — kör alla tre i ett svep

Klistra in detta för att generera samtliga attacker:

```bash
# SQL injection
curl -s -o /dev/null "http://localhost:3000/rest/products/search?q=apple%27%20UNION%20SELECT%20%2A%20FROM%20users--"

# Path traversal
curl -s -o /dev/null "http://localhost:3000/%2e%2e/%2e%2e/%2e%2e/etc/passwd"

# XSS
curl -s -o /dev/null "http://localhost:3000/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
```

Vänta cirka 10–30 sekunder, ladda om Threat Hunting i dashboarden, och du
ska se nya alerts från `agent.name: "nginx-proxy"`.

---

### Vad vi har lärt oss

1. **Loggformatet styr vad SIEM:en ser.** Juice Shop's egen logg matchar inga
   default-decoders → noll alerts. Nginx access.log matchar `web-accesslog`-
   decodern → alerts flödar.

2. **Reverse proxy är inte bara för prestanda.** Att ha nginx framför sin app
   ger en gratis, branschstandard-loggrad där SIEM kan plugga in.

3. **Statuskoden räcker inte.** En "200 OK" kan dölja en lyckad attack;
   en "400 Bad Request" kan vara en avvärjd attack. Wazuh ger oss *URL-
   mönster + status* tillsammans — det är det som gör skillnad.

---

### Vidare läsning

- [OWASP Juice Shop — officiella sidan][1]
- [Pwning OWASP Juice Shop — companion guide][2]
- Wazuh-regler för web-attacker finns i `etc/ruleset/rules/0260-web_rules.xml`
  inne i manager-containern. Gå in med
  `docker compose exec wazuh.manager bash` och utforska.

[1]: https://juice-shop.github.io/
[2]: https://pwning.owasp-juice.shop/companion-guide/latest/index.html
