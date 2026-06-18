function sendJson(res, status, payload) {
  if (res.writableEnded) return;
  let body;
  try {
    body = JSON.stringify(payload);
  } catch (error) {
    status = 500;
    body = JSON.stringify({ ok: false, error: `Response could not be serialized: ${error.message}` });
  }
  if (res.headersSent) {
    res.end(body);
    return;
  }
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "access-control-allow-origin": "*"
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > 64_000) {
        reject(new Error("Request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

module.exports = {
  readBody,
  sendJson
};
