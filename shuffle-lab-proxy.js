// shuffle-lab-proxy.js — logger + reverse proxy för Shuffle-labben
// Kör:      node shuffle-lab-proxy.js        (kräver Node 18+)
// Exponera: ngrok http 3010                  (EN tunnel räcker för hela loopen)
//
// Två roller i samma server:
//   POST /log       -> incidentnotiser från Shuffle loggas i terminalen
//   GET  /wazuh/... -> vidarebefordras till Wazuh-indexern (https://localhost:9200)
//
// Poängen: proxyn kapslar in båda fulhackena på serversidan — basic auth-
// inloggningen och det självsignerade certet. Shuffle ser bara en vanlig
// HTTPS-adress (ngroks giltiga cert) och behöver varken auth eller
// SSL-undantag. Jämför med nginx-proxy i labbstacken — samma roll.

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'; // ENDAST LABB: lita på Wazuhs
// självsignerade cert. Ofarligt här: det hoppet går localhost -> localhost.

const http = require('http');
const fs = require('fs');
const path = require('path');

// Loggfil bredvid scriptet - gitignorad (se .gitignore). Lätt att hitta,
// lätt att radera. Terminalen visar samma sak live under demon.
const LOG_FILE = path.join(__dirname, 'shuffle-lab.log');

const PORT = process.env.PORT || 3010;
const INDEXER = 'https://localhost:9200';
const AUTH = 'Basic ' + Buffer.from('admin:SecretPassword').toString('base64');

const server = http.createServer(async (req, res) => {

  // 1) Brevlådan: Shuffle POST:ar incidentnotiser hit
  if (req.method === 'POST' && req.url === '/log') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      const header = '\n=== INCIDENT ' + new Date().toLocaleString('sv-SE') + ' ===';
      let pretty;
      try { pretty = JSON.stringify(JSON.parse(body), null, 2); }
      catch { pretty = body; }
      console.log(header);
      console.log(pretty);
      fs.appendFileSync(LOG_FILE, header + '\n' + pretty + '\n');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{"ok":true}');
    });
    return;
  }

  // 2) Reverse proxy: /wazuh/... -> indexern. Endast GET — läsning, aldrig skrivning.
  if (req.url.startsWith('/wazuh/')) {
    if (req.method !== 'GET') {
      res.writeHead(405, { 'Content-Type': 'application/json' });
      return res.end('{"error":"Endast GET vidarebefordras"}');
    }
    const target = INDEXER + req.url.slice('/wazuh'.length);
    try {
      const upstream = await fetch(target, { headers: { Authorization: AUTH } });
      const text = await upstream.text();
      res.writeHead(upstream.status, { 'Content-Type': 'application/json' });
      res.end(text);
    } catch (err) {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Kunde inte nå indexern: ' + err.message }));
    }
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end('{"error":"Använd POST /log eller GET /wazuh/..."}');
});

server.listen(PORT, () => {
  console.log(`Logger + proxy igång på http://localhost:${PORT}`);
  console.log(`  POST /log        — incidentnotiser loggas här`);
  console.log(`  GET  /wazuh/...  — vidarebefordras till ${INDEXER}`);
});
