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

### Generationshastighet

flog producerar:
- Apache: en rad **var 2:a sekund**
- Syslog: en rad **var 3:e sekund**
- JSON: en rad **var 4:e sekund**

Du kan justera takten i `flog-noise/entrypoint.sh` (`-d` flaggan).

> **Varning:** filerna växer obegränsat. För labbmiljö är det inget problem
> (några MB per dag), men kör inte detta över helger utan att rotera. För
> produktion skulle man använda `logrotate` eller flog:s `-p` (split-by).
