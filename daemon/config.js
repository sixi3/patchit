const crypto = require("crypto");
const fs = require("fs");

function createConfigManager({ loupeHome, configFile, githubOAuthClientId }) {
  const config = loadConfig(configFile);

  function saveConfig() {
    fs.mkdirSync(loupeHome, { recursive: true });
    fs.writeFileSync(configFile, JSON.stringify(config, null, 2));
    try { fs.chmodSync(configFile, 0o600); } catch {}
  }

  function createSecretToken() {
    return crypto.randomBytes(32).toString("base64url");
  }

  function hashToken(token) {
    return crypto.createHash("sha256").update(String(token || "")).digest("hex");
  }

  function ensureDeviceRegistry() {
    if (!Array.isArray(config.devices)) config.devices = [];
    if (config.apiToken && !config.devices.some((device) => device.tokenHash === hashToken(config.apiToken))) {
      config.devices.push({
        id: `device-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
        name: "Paired browser",
        tokenHash: hashToken(config.apiToken),
        createdAt: new Date().toISOString(),
        lastSeenAt: null,
        lastIp: null,
        revokedAt: null
      });
      saveConfig();
    }
  }

  function ensureAlphaAuth() {
    if (!config.apiToken) {
      config.apiToken = createSecretToken();
      saveConfig();
    }
    ensureDeviceRegistry();
  }

  function tokenPreview(token) {
    if (!token) return null;
    return `${token.slice(0, 6)}...${token.slice(-4)}`;
  }

  function getGithubAccessToken() {
    return config.github?.accessToken || config.githubToken || "";
  }

  function configSummary() {
    const githubAuth = config.github || {};
    return {
      auth: {
        enabled: true,
        tokenPreview: tokenPreview(config.apiToken)
      },
      github: {
        configured: !!getGithubAccessToken(),
        login: githubAuth.login || config.githubLogin || null,
        avatarUrl: githubAuth.avatarUrl || null,
        authType: githubAuth.accessToken ? "oauth" : config.githubToken ? "pat" : null,
        oauthClientConfigured: !!githubOAuthClientId
      },
      devices: (config.devices || []).filter((device) => !device.revokedAt).map((device) => ({
        id: device.id,
        name: device.name,
        createdAt: device.createdAt,
        lastSeenAt: device.lastSeenAt,
        lastIp: device.lastIp
      }))
    };
  }

  function saveGithubOAuth(tokenPayload, viewer, scopes) {
    config.github = {
      accessToken: tokenPayload.access_token,
      tokenType: tokenPayload.token_type || "bearer",
      scope: tokenPayload.scope || scopes,
      login: viewer?.login || null,
      avatarUrl: viewer?.avatar_url || null,
      connectedAt: new Date().toISOString()
    };
    delete config.githubToken;
    delete config.githubLogin;
    saveConfig();
  }

  function clearGithubAuth() {
    delete config.github;
    delete config.githubToken;
    delete config.githubLogin;
    saveConfig();
  }

  function requestAuthToken(req, url) {
    const headerToken = req.headers["x-loupe-token"];
    if (typeof headerToken === "string" && headerToken.trim()) return headerToken.trim();

    const auth = req.headers.authorization;
    if (typeof auth === "string" && auth.toLowerCase().startsWith("bearer ")) {
      return auth.slice(7).trim();
    }

    const queryToken = url.searchParams.get("token");
    return queryToken ? queryToken.trim() : "";
  }

  function isAuthorized(req, url, getClientIp) {
    const token = requestAuthToken(req, url);
    if (!token) return false;
    if (config.apiToken && token === config.apiToken) return true;
    const tokenHash = hashToken(token);
    const device = (config.devices || []).find((item) => item.tokenHash === tokenHash && !item.revokedAt);
    if (!device) return false;
    device.lastSeenAt = new Date().toISOString();
    device.lastIp = getClientIp(req).replace(/^::ffff:/, "");
    saveConfig();
    return true;
  }

  return {
    config,
    clearGithubAuth,
    configSummary,
    createSecretToken,
    ensureAlphaAuth,
    ensureDeviceRegistry,
    getGithubAccessToken,
    hashToken,
    isAuthorized,
    requestAuthToken,
    saveConfig,
    saveGithubOAuth,
    tokenPreview
  };
}

function loadConfig(configFile) {
  try {
    return JSON.parse(fs.readFileSync(configFile, "utf8"));
  } catch {
    return {};
  }
}

module.exports = {
  createConfigManager
};
