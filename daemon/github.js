const https = require("https");

function githubRequest(pathname, token) {
  return githubApiRequest("GET", pathname, token);
}

function githubApiRequest(method, pathname, token, payload = null) {
  const body = payload ? JSON.stringify(payload) : "";
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: "api.github.com",
      path: pathname,
      method,
      headers: {
        "user-agent": "loupe-mac-daemon",
        accept: "application/vnd.github+json",
        "x-github-api-version": "2022-11-28",
        authorization: `Bearer ${token}`,
        ...(body ? { "content-type": "application/json", "content-length": Buffer.byteLength(body) } : {})
      }
    }, (res) => {
      let body = "";
      res.on("data", (chunk) => { body += chunk; });
      res.on("end", () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try { resolve(JSON.parse(body)); } catch (error) { reject(error); }
        } else {
          const err = new Error(`GitHub ${res.statusCode}: ${body.slice(0, 300)}`);
          err.statusCode = res.statusCode;
          reject(err);
        }
      });
    });
    req.on("error", reject);
    req.setTimeout(15_000, () => req.destroy(new Error("GitHub request timeout")));
    if (body) req.write(body);
    req.end();
  });
}

function githubGraphqlRequest(token, query, variables = {}) {
  return githubApiRequest("POST", "/graphql", token, { query, variables });
}

function githubOAuthPost(pathname, params) {
  const body = new URLSearchParams(params).toString();
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: "github.com",
      path: pathname,
      method: "POST",
      headers: {
        "user-agent": "loupe-mac-daemon",
        accept: "application/json",
        "content-type": "application/x-www-form-urlencoded",
        "content-length": Buffer.byteLength(body)
      }
    }, (res) => {
      let responseBody = "";
      res.on("data", (chunk) => { responseBody += chunk; });
      res.on("end", () => {
        let parsed = {};
        try { parsed = JSON.parse(responseBody); } catch {
          const query = new URLSearchParams(responseBody);
          parsed = Object.fromEntries(query.entries());
        }
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(parsed);
        } else {
          const err = new Error(parsed.error_description || parsed.error || `GitHub OAuth ${res.statusCode}`);
          err.statusCode = res.statusCode;
          err.payload = parsed;
          reject(err);
        }
      });
    });
    req.on("error", reject);
    req.setTimeout(15_000, () => req.destroy(new Error("GitHub OAuth request timeout")));
    req.write(body);
    req.end();
  });
}

module.exports = {
  githubApiRequest,
  githubGraphqlRequest,
  githubOAuthPost,
  githubRequest
};
