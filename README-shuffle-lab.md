# Shuffle-labben: hela SOAR-loopen med EN ngrok-tunnel

Den här branchen innehåller allt för övningen "Shuffle-loopen klar":
Wazuh skickar larm till ditt Shuffle-workflow, workflowet anrikar via
Wazuhs API och skickar en färdig incidentnotis tillbaka till din dator.

Nyheten mot artikeln: **`shuffle-lab-proxy.js`** — en Node-server som är
både din logger och en reverse proxy. Då räcker **en enda ngrok-tunnel**
för båda riktningarna (gratis-ngrok tillåter bara en), och Shuffles
HTTP-noder behöver varken inloggning eller SSL-undantag.

## Starta

```bash
docker compose up -d          # labbmiljön (som vanligt)
node shuffle-lab-proxy.js     # logger + proxy på port 3010 (kräver Node 18+)
ngrok http 3010               # i en egen terminal — anteckna adressen
```

Din ngrok-adress (t.ex. `https://abc123.ngrok-free.app`) ger nu:

| Väg | Vad | Används i Shuffle som |
|---|---|---|
| `GET /wazuh/...` | vidarebefordras till indexern (proxyn lägger på auth + accepterar labbcertet) | HTTP-nodens URL för anrikning |
| `POST /log` | skrivs ut i terminalen där proxyn kör | POST-nodens URL för incidentnotisen |

## Wazuh → Shuffle

1. Skapa workflow i Shuffle, dra in en **Webhook**-trigger, tryck **Start**, kopiera URL:en.
2. Öppna `wazuh/config/wazuh_cluster/wazuh_manager.conf`, ersätt
   `REPLACE_WITH_YOUR_SHUFFLE_WEBHOOK_URL` med din URL.
3. `docker compose restart wazuh.manager`
4. Testa webhooken för hand FÖRST (felsökningslager 1):
   `curl -X POST "DIN_WEBHOOK_URL" -H "Content-Type: application/json" -d '{"test":"hej"}'`
5. Kör en attack och se larmet i Runs — obs att Wazuh skickar ett "kuvert":
   `rule_id`, `severity`, `title` på toppnivå, originallarmet under `all_fields`.

## Shuffle-flödet

Webhook → **Condition** (`$exec.rule_id` equals `31106`) →
**HTTP GET** `https://DIN-NGROK-ADRESS/wazuh/wazuh-alerts-*/_search?q=rule.id:31106&size=5&sort=@timestamp:desc`
(ingen auth, SSL-verifiering PÅ — proxyn sköter resten) →
**Shuffle Tools** som bygger notisen →
**HTTP POST** `https://DIN-NGROK-ADRESS/log` med body `$nodnamnet_på_din_notisnod`.

Kör attackerna (se README-nginx-attacks.md / `simulera-attackkedja.sh`) och
titta i terminalen där proxyn kör — notisen ska landa där, hela varvet runt.

## Varför en proxy? (läs detta, det är poängen)

- **En tunnel i stället för två** — gratis-ngrok tillåter bara en.
- **Hemligheterna stannar hemma:** lösenordet och cert-undantaget ligger i
  proxyn på din maskin, inte i molnet.
- **Endast GET släpps igenom till Wazuh** — läsning, aldrig skrivning.
  Fundera: varför är det en viktig begränsning när adressen är publik?
- Detta är samma roll som `nginx-proxy` spelar i labbstacken — en reverse
  proxy som står framför en tjänst och bestämmer vad som släpps igenom.
