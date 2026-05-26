# Hur mycket loggar nginx — och kan man logga mer?

En av er ställde en mycket bra fråga: när ni tittar på de råa loggfilerna
i nginx-containern — *hur mycket* loggas där egentligen, och kan man höja
loggningsgraden för att se mer?

Den här artikeln går igenom svaret som en liten utredning, för det visar
sig leda till en överraskning som är värd att förstå.

---

## Utgångsläget: vad `combined` loggar

Vår nginx-proxy använder nginx standard-format som heter **`combined`**.
Varje request blir **en rad** i `/var/log/nginx/access.log`. En typisk
rad ser ut så här:

```
172.67.157.37 - - [26/May/2026:05:03:33 +0000] "GET /rest/products/search?q=apple' UNION SELECT 1-- HTTP/1.1" 500 994 "-" "curl/8.7.1"
```

Den innehåller:

| Del | Vad |
|---|---|
| `172.67.157.37` | Klient-IP |
| `[26/May/...]` | Tidsstämpel |
| `"GET /... HTTP/1.1"` | **Request-line** — metod, URL (med query-string), protokoll |
| `500` | HTTP-statuskod |
| `994` | Svarets storlek i byte |
| `"-"` | Referer |
| `"curl/8.7.1"` | User-Agent |

Så **ja — varje request loggas.** Men bara *metadata om* requesten.

## Varför era POST-attacker "försvinner"

Titta noga på vad som *inte* finns i raden ovan:

- **Request-body** (POST/PUT-payload)
- **Response-body** (vad servern svarade med)
- **Headers** (utöver referer och user-agent), cookies, tokens

Det förklarar varför en login bypass via SQL injection blir osynlig.
Attacken skickas som en POST där payloaden ligger i **body**:

```bash
curl -X POST http://localhost:3000/rest/user/login \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@juice-sh.op'"'"' OR 1=1--","password":"x"}'
```

Men i access.log blir det bara:

```
172.67.157.37 - - [...] "POST /rest/user/login HTTP/1.1" 200 799 "-" "curl/8.7.1"
```

SQL injection-payloaden syns **inte** — bara att någon gjorde en POST mot
`/rest/user/login` som fick svar 200. För Wazuh ser det ut som en
fullständigt normal inloggning. **Noll alerts.**

---

## Kan man logga mer? Ja — med ett eget log-format

nginx låter dig definiera ett eget `log_format` med fler variabler. Den
intressanta för oss är **`$request_body`** — den fångar POST/PUT-payloaden:

```nginx
log_format utokad '$remote_addr - $remote_user [$time_local] '
                  '"$request" $status $body_bytes_sent '
                  '"$http_referer" "$http_user_agent" '
                  'rt=$request_time body="$request_body"';
```

Byter vi access.log till det formatet och kör samma login bypass igen:

```
172.67.157.37 - - [...] "POST /rest/user/login HTTP/1.1" 200 799 "-" "curl/8.7.1" rt=0.102 body="{\x22email\x22:\x22admin@juice-sh.op' OR 1=1--\x22,\x22password\x22:\x22hemligt\x22}"
```

Nu syns payloaden! `admin@juice-sh.op' OR 1=1--` står klart och tydligt i
`body="..."`-fältet. (nginx escapar citationstecken som `\x22`.)

**Problemet löst?** Nja. Här kommer överraskningen.

---

## Överraskningen: att logga MER fick Wazuh att se MINDRE

När vi bytte formatet på access.log, körde vi om en **GET-baserad SQL
injection** som vi *vet* triggade Wazuh tidigare (rule 31103). Resultatet:

> **Noll alerts. Inte ens den attack som fungerade förut.**

Vad hände? Wazuhs `web-accesslog`-decoder är byggd för att förstå *exakt*
combined-format. Den förväntar sig att raden **slutar** efter
user-agent-fältet. När vi la till `rt=... body="..."` på slutet kände den
inte längre igen raden — och då parsas **hela raden inte alls**.

Konsekvensen: ingen decoder-match → ingen regel triggar → **all
web-detection slutade fungera**, inklusive de attacker som tidigare syntes.

Det här är en av de viktigaste lärdomarna i hela kursen:

> **Att logga mer data kan paradoxalt nog göra att din SIEM ser mindre —
> om formatet inte matchar vad din decoder förväntar sig.**

I en riktig SOC är detta ett klassiskt självmål: någon "förbättrar"
loggningen på en webserver, och plötsligt slutar säkerhetsteamets alerts
komma in — utan att någon märker det förrän det är för sent.

---

## Det rätta sättet: två loggar

Lösningen är att **inte röra** den logg som Wazuh läser, utan skriva en
*andra* logg med det utökade formatet. nginx kan skriva flera access-loggar
samtidigt:

```nginx
access_log /var/log/nginx/access.log          combined;   # Wazuh läser denna
access_log /var/log/nginx/access_detailed.log utokad;     # innehåller body
```

Efter den ändringen:

- `access.log` är ren combined → Wazuhs decoder är nöjd, rule 31103
  triggar igen på GET-SQLi
- `access_detailed.log` innehåller POST-body:n → tillgänglig för djupare
  analys

Båda världarna: befintlig detektion intakt, *och* den extra datan finns.

---

## Hur vi ändrade konfigurationen — och hur det hänger ihop med Docker

Ändringen gjordes i `nginx-proxy/default.conf`. Konkret la vi till en
`log_format`-definition (utanför `server`-blocket) och en andra
`access_log`-rad:

```nginx
# Nytt: eget format som även loggar request-tid och POST/PUT-body
log_format utokad '$remote_addr - $remote_user [$time_local] '
                  '"$request" $status $body_bytes_sent '
                  '"$http_referer" "$http_user_agent" '
                  'rt=$request_time body="$request_body"';

server {
    ...
    access_log /var/log/nginx/access.log          combined;   # oförändrad
    access_log /var/log/nginx/access_detailed.log utokad;     # ny
    ...
}
```

En viktig detalj med vår Docker-uppsättning: `default.conf` är **inte**
monterad som en volym — den **kopieras in i imagen** när containern byggs
(`COPY default.conf ...` i `nginx-proxy/Dockerfile`). Det betyder att en
ändring i filen inte slår igenom förrän man **bygger om** imagen:

```bash
docker compose build nginx-proxy
docker compose up -d nginx-proxy
```

Jämför med Wazuh-managerns konfiguration, som *är* volym-monterad — där
räcker en omstart utan rebuild. Olika delar av stacken laddar alltså sin
konfiguration på olika sätt, och det är värt att hålla reda på vilket som
gäller var.

---

## Men ser Wazuh POST-attacken nu?

Nej — inte automatiskt, och det är värt att förstå varför.

Även om body:n nu finns i `access_detailed.log` så:

1. Wazuh-agenten läser den filen bara om vi **pekar ut den** med en
   `<localfile>`-rad i agentens konfiguration.
2. Och även om agenten läser den, finns det **ingen decoder** som vet hur
   man plockar ut `body="..."`-fältet och **ingen regel** som matchar
   SQL injection-mönster *i body*.

Så för att Wazuh ska kunna *larma* på en POST-body-attack krävs tre steg:

1. **Logga** body (nginx-konfig) — det här gjorde vi
2. **Samla in** loggen (agentens `<localfile>`)
3. **Förstå** den (decoder + regel i managern)

Vi har gjort steg 1. Steg 2 och 3 är "nästa nivå" — och det är precis
sådant arbete en SOC-ingenjör gör för att täcka en upptäckt blindspot.

### "Men kan jag inte bara skriva en regel?"

Jo — men det är värt att förstå hur Wazuh fungerar internt här. Det är
**två** komponenter, inte en:

```
rå loggrad  →  DECODER (plockar ut fält)  →  REGEL (matchar fält)  →  alert
```

En **decoder** bryter ut fält ur den råa texten (`data.srcip`, `data.url`,
status osv.). En **regel** matchar sedan mot de fälten och larmar. De
flesta inbyggda web-reglerna kräver att `web-accesslog`-decodern fyrat
av *först* — ingen decoder, inga web-regler.

Det ger två vägar:

**Väg 1 — regel som matchar rå text (fungerar, men trubbigt).** En regel
kan matcha direkt mot den råa raden utan decoder:

```xml
<rule id="100100" level="10">
  <match>UNION SELECT</match>
  <description>SQL injection-mönster i rå logg</description>
</rule>
```

Den fyrar på vilken rad som helst som innehåller "UNION SELECT" —
inklusive `body="..."`. Så ja, en regel *ensam* kan larma. **Men** du
tappar all struktur: ingen källa-IP, ingen URL, ingen status — bara "en
rad innehöll det här mönstret". Svårt att bygga en användbar utredning
på.

**Väg 2 — egen decoder + egna regler (det riktiga sättet).** Skriv först
en decoder som förstår det utökade formatet och plockar ut `body` som ett
eget fält. Skriv sedan regler som matchar mönster *i det fältet* — då får
du tillbaka källa, URL och status, och en alert värd namnet.

Med andra ord: "skriva egna regler" i full mening betyder oftast
**decoder + regler tillsammans**. Att bara skriva en regel räcker om du
nöjer dig med grov rå-text-matchning.

---

## Den röda tråden

Detta knyter ihop hela kursens tema:

- **Loggningsgrad är ett aktivt val.** Default-format loggar sällan allt
  du behöver för säkerhetsanalys.
- **Mer loggning hjälper bara om hela kedjan följer med** — format,
  insamling, decoder, regler.
- **Förändringar i loggformat är farliga** — de kan tyst bryta din
  befintliga detektion.

När du i din inlämningsuppgift diskuterar Wazuhs styrkor och svagheter
(mål 9) är det här ett konkret, självupplevt exempel: SIEM:en är bara så
bra som de loggar den matas med — och de loggarna måste konfigureras med
omsorg.

---

## Varning: att logga body fångar känslig data

Titta en gång till på raden vi loggade när vi körde login bypass:

```
... "POST /rest/user/login HTTP/1.1" 200 799 "-" "curl/8.7.1" rt=0.102 body="{\x22email\x22:\x22admin@juice-sh.op' OR 1=1--\x22,\x22password\x22:\x22hemligt\x22}"
```

Lägg märke till slutet: `password":"hemligt"`. **Lösenordet ligger i
klartext i loggen.** Det gäller varenda inloggning — inte bara vår
attack. Loggar man hela request-body fångar man *allt* användarna skickar:
lösenord, personnummer, betalkortsnummer, session-tokens, privat
meddelandetext.

Det är ett klassiskt säkerhetssjälvmål: man slår på utökad loggning
*för säkerhets skull* och skapar därmed en ny, extremt känslig
datasamling som i sig blir ett högvärdesmål för en angripare.

### Internsäkerhet — vem får läsa loggarna?

När loggarna innehåller credentials gäller **least privilege** hårdare än
någonsin:

- Loggfilerna ska ha restriktiva filrättigheter — bara de tjänstkonton
  och personer som *måste* ska kunna läsa dem.
- I SIEM:en (Wazuh) bör åtkomst styras med roller — alla analytiker
  behöver inte se råa bodys.
- Loggarna bör krypteras i vila och under överföring.
- Ironin: ditt säkerhetsverktyg blir nu en del av din attackyta. Om
  någon kommer åt logglagringen har de plötsligt allas lösenord.

### GDPR-perspektivet

Så fort loggar innehåller personuppgifter (e-post, IP, personnummer,
beteende kopplat till en identifierbar person) gäller GDPR. Några
principer som blir direkt relevanta:

- **Uppgiftsminimering (art. 5).** Du får bara samla in det du faktiskt
  behöver. Att logga *hela* body "för säkerhets skull" är svårt att
  försvara om 99% av innehållet är irrelevant för din detektion.
- **Lagringsminimering (art. 5).** Loggar med personuppgifter kan inte
  sparas hur länge som helst — du behöver en gallringsrutin.
- **Säkerhet vid behandling (art. 32).** Lösenord i klartext i en logg
  kan i sig vara en brist i den tekniska säkerheten.
- **Inbyggt dataskydd (art. 25).** Tänk på detta *innan* du slår på
  loggningen, inte efteråt.
- **Personuppgiftsincident.** Om en logg som innehåller personuppgifter
  läcker är det en anmälningspliktig incident — 72 timmar till IMY. En
  logg full av lösenord som läcker är ett allvarligt sådant fall.

### Vad gör man istället?

- **Maskera känsliga fält.** Logga aldrig lösenord i klartext — ersätt
  värdet med `***` innan det skrivs. (nginx kan inte maskera body-fält
  med standarddirektiv — det kräver Lua/njs eller maskning i
  applikationslagret.)
- **Logga selektivt.** Logga body bara för de endpoints där det faktiskt
  behövs för detektion — inte överallt.
- **Logga hellre mönster än innehåll.** Ofta räcker det att veta *att*
  ett SQLi-mönster förekom, inte att spara hela payloaden för evigt.

Detta är precis den typ av avvägning du kan resonera kring i
slutuppgiftens cybersäkerhetslags- och GDPR-delar: mer loggning ger bättre
detektion men ökar både din attackyta och ditt dataskyddsansvar. Det finns
ingen gratis lunch.

---

## Prova själv

Den färdiga konfigurationen med båda loggarna finns i branchen
**nginx-utokad-loggning**:

<https://github.com/ironboy/logghantering-docker/tree/nginx-utokad-loggning>

Jämför `access.log` och `access_detailed.log` efter att du kört en
POST-attack:

```bash
docker compose exec nginx-proxy tail -5 /var/log/nginx/access.log
docker compose exec nginx-proxy tail -5 /var/log/nginx/access_detailed.log
```

Fundera på: hur skulle Wazuh kunna larma när `body="..."` innehåller
`OR 1=1` eller `UNION SELECT`? Svaret är att man kan skriva **egna
regler** i Wazuh som matchar sådana mönster. Vi har inte gått igenom
regelskrivning än, men om du är nyfiken finns Wazuhs egen dokumentation
som en bra startpunkt:
[Custom rules](https://documentation.wazuh.com/current/user-manual/ruleset/rules/custom.html).
