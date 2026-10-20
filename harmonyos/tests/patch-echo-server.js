const http = require('http');
const fs = require('fs');

const receiptPath = '/tmp/patch-echo-receipt.jsonl';
try {
  fs.unlinkSync(receiptPath);
} catch (_e) {}

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    const record = {
      timestamp: new Date().toISOString(),
      method: req.method,
      url: req.url,
      headers: req.headers,
      body: body
    };
    console.log('[ECHO_RECEIVED]', JSON.stringify(record));
    fs.appendFileSync(receiptPath, JSON.stringify(record) + '\n');
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, received: record }));
  });
});

server.listen(9198, '127.0.0.1', () => {
  console.log('Echo server listening on 127.0.0.1:9198');
});
