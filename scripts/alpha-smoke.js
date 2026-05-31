#!/usr/bin/env node
"use strict";

const http = require("http");
const https = require("https");
const fs = require("fs");
const os = require("os");
const path = require("path");

const args = process.argv.slice(2);
const host = valueFor("--host") || process.env.LOUPE_HOST || "http://127.0.0.1:4173";
const token = valueFor("--token") || process.env.LOUPE_TOKEN || localToken() || "";

function valueFor(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : "";
}

function localToken() {
  const loupeHome = process.env.LOUPE_HOME || path.join(os.homedir(), ".loupe");
  try {
    const config = JSON.parse(fs.readFileSync(path.join(loupeHome, "config.json"), "utf8"));
    return typeof config.apiToken === "string" ? config.apiToken : "";
  } catch {
    return "";
  }
}

function request(pathname, { method = "GET", body = null, auth = true } = {}) {
  const url = new URL(pathname, host);
  const client = url.protocol === "https:" ? https : http;
  const payload = body ? Buffer.from(JSON.stringify(body)) : null;
  const headers = { accept: "application/json" };
  if (payload) {
    headers["content-type"] = "application/json";
    headers["content-length"] = String(payload.length);
  }
  if (auth && token) headers["x-loupe-token"] = token;

  return new Promise((resolve) => {
    const req = client.request(url, { method, headers, timeout: 10_000 }, (res) => {
      let raw = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { raw += chunk; });
      res.on("end", () => {
        let json = null;
        try { json = raw ? JSON.parse(raw) : null; } catch {}
        resolve({ status: res.statusCode, json, raw });
      });
    });
    req.on("timeout", () => req.destroy(new Error("timeout")));
    req.on("error", (error) => resolve({ status: 0, error }));
    if (payload) req.write(payload);
    req.end();
  });
}

function pass(label, detail = "") {
  console.log(`PASS ${label}${detail ? ` - ${detail}` : ""}`);
}

function warn(label, detail = "") {
  console.log(`WARN ${label}${detail ? ` - ${detail}` : ""}`);
}

function fail(label, detail = "") {
  console.log(`FAIL ${label}${detail ? ` - ${detail}` : ""}`);
  failures += 1;
}

let failures = 0;

(async () => {
  console.log(`Loupe alpha smoke: ${host}`);

  const pairing = await request("/api/pairing/status", { auth: false });
  if (pairing.status === 200 && pairing.json?.ok) {
    pass("daemon reachable", `pairing token ${pairing.json.tokenPreview || "available"}`);
  } else {
    fail("daemon reachable", pairing.error?.message || `HTTP ${pairing.status}`);
    process.exit(1);
  }

  if (!token) {
    warn("authenticated checks skipped", "set LOUPE_TOKEN, pass --token, or run on the Mac with ~/.loupe/config.json");
    process.exit(failures ? 1 : 0);
  }

  const health = await request("/api/health");
  if (health.status === 200 && health.json?.ok) {
    const harness = health.json.defaultHarness || "unknown";
    pass("health", `default harness ${harness}`);
    const readiness = health.json.workspaceReadiness || [];
    if (!readiness.length) {
      warn("workspace readiness", "no configured workspaces");
    } else {
      for (const item of readiness) {
        const name = item.workspacePath || item.workspaceId || "workspace";
        if (item.canDispatch) {
          pass("workspace dispatch-ready", name);
        } else {
          warn("workspace not dispatch-ready", `${name}: ${(item.blockers || []).join(" ")}`);
        }
      }
    }
    if (health.json.config?.github?.login) {
      pass("GitHub connected", health.json.config.github.login);
    } else {
      warn("GitHub connected", "not connected yet; iOS should show Connect GitHub");
    }
  } else {
    fail("health", health.json?.error?.message || health.json?.error || health.error?.message || `HTTP ${health.status}`);
  }

  const invalidDispatch = await request("/api/sessions/start", {
    method: "POST",
    body: { message: "" }
  });
  if (invalidDispatch.status === 400 && invalidDispatch.json?.ok === false) {
    pass("session start validation", "empty dispatch is rejected");
  } else {
    fail("session start validation", invalidDispatch.json?.error?.message || invalidDispatch.json?.error || invalidDispatch.error?.message || `HTTP ${invalidDispatch.status}`);
  }

  const inbox = await request("/api/v1/inbox");
  if (inbox.status === 200 && inbox.json?.ok && inbox.json.data) {
    const assigned = inbox.json.data.assigned || [];
    pass("inbox", `${assigned.length} assigned issue(s)`);
    const stale = assigned.filter((item) => item.blueprint?.stale);
    if (stale.length) {
      pass("stale blueprint payload", `${stale.length} stale issue(s), staleFiles=${JSON.stringify(stale[0].blueprint.staleFiles || [])}`);
    }
  } else if (inbox.status === 401 && inbox.json?.error?.code === "GITHUB_AUTH_REQUIRED") {
    pass("inbox auth gate", "GitHub auth required");
    const refresh = await request("/api/v1/blueprints/owner/repo/1/refresh", {
      method: "POST",
      body: {}
    });
    if (refresh.status === 401 && refresh.json?.error?.code === "GITHUB_AUTH_REQUIRED") {
      pass("refresh auth gate", "GitHub auth required");
    } else {
      fail("refresh auth gate", refresh.json?.error?.message || refresh.json?.error || refresh.error?.message || `HTTP ${refresh.status}`);
    }
  } else {
    fail("inbox", inbox.json?.error?.message || inbox.json?.error || inbox.error?.message || `HTTP ${inbox.status}`);
  }

  process.exit(failures ? 1 : 0);
})();
