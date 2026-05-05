## Söka i Wazuh efter events från juice-shop

Detta dokument beskriver hur du hittar och tolkar events från
`offer-juice-shop`-containern i Wazuh-dashboarden, samt vad du kan göra om
du saknar specifika events.

---

### Två nivåer: alerts vs raw events

Wazuh skiljer på två saker:

- **Alerts** — events som matchat en *decoder* + *rule* (har severity-level).
  Indexeras i `wazuh-alerts-*` och visas i dashboardens UI.
- **Raw events** — allt som agenten läser och skickar in. Hamnar inte i UI:n
  per default; bara om du explicit aktiverar arkivering av dem.

Default-vyn i dashboarden visar bara alerts. Det är där de flesta studenter
hittar 99% av det de letar efter.

---

### Söka alerts i dashboarden — snabbaste vägen

1. Gå till `https://localhost`, logga in
2. Klicka hamburgermenyn (☰) uppe till vänster → **Threat Hunting**
3. I sökrutan högst upp, skriv:
   ```
   agent.name: "offer-juice-shop"
   ```
4. Sätt tidsfönstret uppe till höger till t.ex. **Last 1 hour**

Du ser då alla alerts som denna agent producerat under det senaste timmen.

**Alternativ navigering:**
- Hamburger → **Endpoints / Agents** → klicka på `offer-juice-shop` →
  agent-specifik vy med samma data

---

### Användbara queries att prova

| Vad du letar efter | Query |
|---|---|
| Alla events från denna agent | `agent.name: "offer-juice-shop"` |
| Bara medel/hög-allvarliga | `agent.name: "offer-juice-shop" AND rule.level >= 7` |
| Bara CIS Benchmark-resultat | `agent.name: "offer-juice-shop" AND decoder.name: "sca"` |
| Failed CIS-checks | `agent.name: "offer-juice-shop" AND rule.id: 19007` |
| Wazuh-uppstart | `decoder.name: "ossec" AND agent.name: "offer-juice-shop"` |

Spara bra queries via "Save" uppe till höger om du vill kunna återanvända
dem.

---

### Vad du *kommer* se direkt efter start

Wazuh-agenten kör en automatisk **SCA-skanning** (Security Configuration
Assessment) mot containerns host vid uppstart — det är de **CIS Debian Linux 12
Benchmark**-resultat du ser. Det är inte attacker, utan compliance-checks
av offer-containerns egen konfiguration.

Det här är pedagogiskt en bra ingångspunkt: studenter får se hur Wazuh
övervakar inte bara *trafik* utan också *konfigurationsläge* på endpoints.

---

### Men juice-shops egna app-loggar då?

Här blir det intressant — och det är **inte en bugg**.

Wazuh-agenten läser `/var/log/juice-shop.log` och skickar raderna till
managern. Men managern har ingen *decoder* eller *regel* som matchar Juice
Shops loggformat → de blir **raw events** som inte indexeras som alerts.

Det är en grundpoäng i Wazuh-arkitekturen:

> Agenten samlar in. Managern decodar och matchar mot regler. Bara träffar
> blir alerts.

För att kunna *jobba med* juice-shops egna app-loggar har du tre val:

#### Alternativ 1: Aktivera arkivering (`logall_json`)

Då hamnar **allt** som agenten skickar i ett separat index
(`wazuh-archives-*`). Du kan sedan söka i dem via Discover-vyn.

I `wazuh/config/wazuh_cluster/wazuh_manager.conf`:

```xml
<global>
  ...
  <logall_json>yes</logall_json>
  ...
</global>
```

Sedan: `docker compose restart wazuh.manager`.

**Pris:** 3–5× mer diskutrymme vid hög trafik. För labbmiljö är det ok.

#### Alternativ 2: Titta i loggfilen direkt i containern

För snabb sondering — vad finns där över huvud taget?

```bash
docker compose exec offer-juice-shop tail -f /var/log/juice-shop.log
```

Användbart innan du skriver regler — du behöver veta hur en typisk
juice-shop-rad ser ut.

#### Alternativ 3: Skriv en custom regel

Det "riktiga" sättet — och pedagogiskt rikt material för senare lektion. Det
illustrerar hela pipeline:n: decoder → rule → alert.

Custom regler hamnar i `wazuh_manager.conf`:s `etc/rules/`-katalog inne i
managern. Vi tar det när vi kommer till regelhantering i kursen.

---

### Sammanfattning

- **Hitta alerts:** `agent.name: "offer-juice-shop"` i Threat Hunting
- **Förvänta dig:** SCA / CIS-events vid uppstart, inte juice-shop-app-events
- **Vill se app-events:** aktivera `logall_json`, tail:a filen, eller skriv
  custom regler
- **Pedagogisk poäng:** "Wazuh läser allt vi pekar ut, men du får bara
  *alerts* för det som matchar en regel."
