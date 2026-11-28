'use strict';
const assert = require('node:assert/strict');

// headers maps a header to the value every reply carries, null for one no reply may carry.
async function assertServes(server, table, headers, label = '') {
  const at = `http://127.0.0.1:${server.address().port}`;
  try {
    for (const [url, status, type] of table) {
      const response = await fetch(at + url);
      assert.equal(response.status, status, `${label}${url}`);
      if (type) assert.equal(response.headers.get('content-type'), type, `${label}${url}`);
      for (const [header, value] of Object.entries(headers)) assert.equal(response.headers.get(header), value, `${label}${url} ${header}`);
    }
  } finally { server.close(); }
}

module.exports = { assertServes };
