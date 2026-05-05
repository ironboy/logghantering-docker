## Flog — jämför logformat i samma SIEM

Denna branch (`flog`) lägger till en container `flog-noise` som genererar
**fake-loggar i tre olika format samtidigt**:

| Format | Fil | Wazuh `log_format` |
|---|---|---|
| Apache Combined | `/var/log/flog/apache.log` | `apache` |
| Syslog (RFC 3164) | `/var/log/flog/syslog.log` | `syslog` |
| JSON | `/var/log/flog/json.log` | `json` |

Alla tre filer läses av samma Wazuh-agent inne i `flog-noise`-containern.
Studenter får se *exakt* hur olika format syns (eller inte syns) i Wazuh.

---

### Vad är flog?

[mingrammer/flog](https://github.com/mingrammer/flog) är ett litet
Go-program som genererar realistiska fake-loggar i flera format. Vi använder
det för att skapa **bakgrundsbrus** i labbmiljön — det får dashboarden att
se "levande" ut även när inga riktiga attacker pågår.

> **Notera:** mingrammer/flog är inte uppdaterad på 5+ år. Det är acceptabelt
> i en utbildningsmiljö, men nämn det för studenterna — det är ett bra
> exempel på hur ett **övergivet open source-verktyg** ser ut. I produktion
> skulle man välja något aktivt underhållet (eller skriva eget).

---

### Vad du ser i dashboarden

Sök i Threat Hunting:

```
agent.name: "flog-noise"
```

Du kommer främst se alerts från **apache.log**. Varför? Wazuhs inbyggda
`web-accesslog`-decoder känner igen Combined Log Format och triggar regler
för 4xx/5xx-statuskoder, common web attacks osv. flog genererar slumpade
status-koder, så vissa rader blir 4xx eller 5xx → alert.

Sök specifikt efter web-events från flog:

```
agent.name: "flog-noise" AND decoder.name: "web-accesslog"
```

---

### Den intressanta jämförelsen

**Apache-loggen** ger massor av alerts:

```
agent.name: "flog-noise" AND location: "/var/log/flog/apache.log"
```

**Syslog-loggen** ger nästan inga alerts:

```
agent.name: "flog-noise" AND location: "/var/log/flog/syslog.log"
```

**JSON-loggen** ger nästan inga alerts:

```
agent.name: "flog-noise" AND location: "/var/log/flog/json.log"
```

Trots att alla tre filer fylls med events i samma takt, och alla tre läses
in av wazuh-agenten med rätt log_format!

### Varför?

- **Apache Combined** matchar Wazuh's inbyggda `web-accesslog`-decoder, som
  i sin tur är kopplad till en stor uppsättning regler (31100-serien). Varje
  rad bryts ned i URL, status, user agent osv., och varje status-kod kollas
  mot regler.

- **RFC 3164 syslog** parsas av Wazuh's syslog-decoder i grundnivå (host,
  program, message), men det finns ingen *regel* som matchar mot generiska
  meddelanden från fake-program. Raden blir ett "raw event" — sparas internt
  men når inte alerts-indexet.

- **JSON** läses av Wazuh's json-decoder, men igen — utan regler som matchar
  flog:s specifika fält ("user-identifier", "request" osv.) blir det bara
  raw events.

---

### Den röda tråden

Det här är samma poäng som i `nginx-foran-juice-shop`-branchen, fast i en
annan riktning:

> Insamling är inte nog. Decoder + rule är det som omvandlar "rader på en
> disk" till "actionable alerts" i en SOC.

I `nginx-foran-juice-shop` lärde vi oss att *rätt format* + *inbyggd regel*
= alerts.

I `flog`-branchen lär vi oss att *insamling i flera format* utan rätt regler
= mest tystnad.

**Lärandemoment:** att skapa en decoder/regel för custom-format är en del
av en SOC-analytikers arbete — vi kommer titta på det senare i kursen.

---

### Kom åt loggrader direkt

För att titta på vad flog faktiskt genererar:

```bash
# Apache Combined-format
docker compose exec flog-noise tail -f /var/log/flog/apache.log

# RFC 3164 syslog
docker compose exec flog-noise tail -f /var/log/flog/syslog.log

# JSON
docker compose exec flog-noise tail -f /var/log/flog/json.log
```

Det är ett bra sätt att se skillnaderna mellan formaten innan ni börjar
diskutera dem i klassen.

---

### Trigger flog ligger och genererar **konstant**

Du behöver inte trigga flog manuellt — den startar automatiskt när
containern startar och kör tre parallella processer i bakgrunden.

| Fil | Format | Takt | Per minut | Per timme |
|---|---|---|---|---|
| `apache.log` | apache_combined | 1 rad / **2 s** | 30 rader | 1 800 |
| `syslog.log` | rfc3164 | 1 rad / **3 s** | 20 rader | 1 200 |
| `json.log` | json | 1 rad / **4 s** | 15 rader | 900 |
| **Totalt** | | | **65 rader/min** | **~3 900/h** |

Mängden är medvetet liten — det är "bakgrundsbrus", inte stresstest.

### Verifiera att det rullar

```bash
docker compose exec flog-noise tail -f /var/log/flog/apache.log
```

Du ska se en ny rad ungefär varannan sekund.

### Ändra intensitet

Redigera `flog-noise/entrypoint.sh` — `-d`-flaggan styr fördröjningen:

```bash
flog -l -w -d 2s -f apache_combined ...    # default: 1 rad / 2 s
flog -l -w -d 200ms -f apache_combined ... # 5 rader/sek = ~18 000/h
flog -l -w -d 50ms -f apache_combined ...  # 20 rader/sek = "stress"
```

Bygg om:
```bash
docker compose up -d --build flog-noise
```

### "Burst" för demo

Vill du skapa en plötslig spik mitt under en lektion — kör en engångskörning
av flog **inne i containern**:

```bash
# 500 rader på en gång till apache.log
docker compose exec flog-noise \
    flog -n 500 -f apache_combined -t log -o /var/log/flog/apache.log -w
```

(`-w` skriver *över* filen — det blir 500 nya rader. Wazuh-agenten upptäcker
ändringen och pumpar in dem på några sekunder.)

### Vad du kan förvänta i dashboarden

Eftersom flog producerar slumpade HTTP-statuskoder triggar Wazuh's
web-accesslog-decoder regler på ungefär 30-40% av apache-raderna (de som
har 4xx/5xx). Det blir cirka **10-12 alerts/minut** från apache-strömmen
— en konstant baseline-aktivitet i dashboarden.

Det är poängen: med flog ser miljön "levande" ut även när inga riktiga
attacker pågår. När studenter sen kör attackerna från
`nginx-foran-juice-shop`-branchen sticker dessa ut på ett sätt som
är pedagogiskt rikt — *bland brus, inte i tystnad*.

### Filstorlek över tid

Filerna växer obegränsat. För labbmiljö är det inget problem (några MB per
dag), men kör inte detta över helger utan att rotera. För produktion skulle
man använda `logrotate` eller flog:s `-p` (split-by).
