const { githubApiRequest, githubGraphqlRequest } = require("./github");

function createPullRequestService({ getGithubAccessToken, sessions }) {
  function findSessionForPr({ owner, repo, number, branch }) {
    const repoFullName = `${owner}/${repo}`;
    const candidates = [...sessions.values()].reverse();
    return candidates.find((session) => {
      if (branch && session.branch?.name === branch && session.branch?.repo === repoFullName) return true;
      return (session.events || []).some((event) =>
        event.type === "branch" &&
        event.kind === "pr_ready" &&
        event.prNumber === number &&
        event.repo === repoFullName
      );
    }) || null;
  }

  async function fetchPullRequestDetail(owner, repo, number) {
    const token = getGithubAccessToken();
    if (!token) {
      const error = new Error("GitHub is not connected.");
      error.statusCode = 401;
      throw error;
    }
    const safe = parseRepoPair(owner, repo);
    const prNumber = Number(number);
    if (!Number.isInteger(prNumber) || prNumber <= 0) {
      const error = new Error("Invalid pull request number.");
      error.statusCode = 400;
      throw error;
    }
    const repoPath = `/repos/${encodeURIComponent(safe.owner)}/${encodeURIComponent(safe.repo)}`;
    const [pr, files, reviews] = await Promise.all([
      githubApiRequest("GET", `${repoPath}/pulls/${prNumber}`, token),
      githubApiRequest("GET", `${repoPath}/pulls/${prNumber}/files?per_page=100`, token),
      githubApiRequest("GET", `${repoPath}/pulls/${prNumber}/reviews?per_page=50`, token)
    ]);
    const [combinedStatus, checkRuns] = await Promise.all([
      githubApiRequest("GET", `${repoPath}/commits/${encodeURIComponent(pr.head.sha)}/status`, token).catch(() => null),
      githubApiRequest("GET", `${repoPath}/commits/${encodeURIComponent(pr.head.sha)}/check-runs?per_page=50`, token).catch(() => null)
    ]);
    const session = findSessionForPr({ owner: safe.owner, repo: safe.repo, number: prNumber, branch: pr.head.ref });
    const handoff = session?.handoff || parsePrHandoff(pr.body || "");
    return {
      repo: `${safe.owner}/${safe.repo}`,
      owner: safe.owner,
      repoName: safe.repo,
      number: pr.number,
      title: pr.title,
      body: pr.body || "",
      url: pr.html_url,
      state: pr.state,
      draft: !!pr.draft,
      merged: !!pr.merged,
      mergeable: pr.mergeable,
      mergeableState: pr.mergeable_state || null,
      author: pr.user?.login || null,
      base: { ref: pr.base.ref, sha: pr.base.sha },
      head: { ref: pr.head.ref, sha: pr.head.sha },
      additions: pr.additions,
      deletions: pr.deletions,
      changedFiles: pr.changed_files,
      checkState: normalizeCheckState({ pr, combinedStatus, checkRuns }),
      checks: {
        combinedState: combinedStatus?.state || null,
        runs: (checkRuns?.check_runs || []).map((run) => ({
          id: run.id,
          name: run.name,
          status: run.status,
          conclusion: run.conclusion,
          url: run.html_url
        }))
      },
      files: (files || []).map((file) => ({
        filename: file.filename,
        status: file.status,
        additions: file.additions,
        deletions: file.deletions,
        changes: file.changes,
        patch: file.patch || "",
        blobUrl: file.blob_url
      })),
      reviews: (reviews || []).map((review) => ({
        id: review.id,
        user: review.user?.login || null,
        state: review.state,
        body: review.body || "",
        submittedAt: review.submitted_at,
        url: review.html_url
      })),
      loupe: {
        sessionId: session?.id || null,
        harness: session?.harnessId || null,
        handoff,
        deviation: session?.deviation || null
      }
    };
  }

  async function submitPullRequestReview(owner, repo, number, { event, body }) {
    const token = getGithubAccessToken();
    if (!token) {
      const error = new Error("GitHub is not connected.");
      error.statusCode = 401;
      throw error;
    }
    const safe = parseRepoPair(owner, repo);
    return githubApiRequest("POST", `/repos/${encodeURIComponent(safe.owner)}/${encodeURIComponent(safe.repo)}/pulls/${Number(number)}/reviews`, token, {
      event,
      body: body || ""
    });
  }

  async function mergePullRequest(owner, repo, number, { commitTitle, commitMessage } = {}) {
    const token = getGithubAccessToken();
    if (!token) {
      const error = new Error("GitHub is not connected.");
      error.statusCode = 401;
      throw error;
    }
    const safe = parseRepoPair(owner, repo);
    const repoPath = `/repos/${encodeURIComponent(safe.owner)}/${encodeURIComponent(safe.repo)}`;
    const prNumber = Number(number);
    const pr = await githubApiRequest("GET", `${repoPath}/pulls/${prNumber}`, token);
    if (pr.draft) {
      await markPullRequestReadyForReview(token, pr.node_id);
    }
    return githubApiRequest("PUT", `${repoPath}/pulls/${prNumber}/merge`, token, {
      merge_method: "squash",
      ...(commitTitle ? { commit_title: commitTitle } : {}),
      ...(commitMessage ? { commit_message: commitMessage } : {})
    });
  }

  async function closePullRequest(owner, repo, number) {
    const token = getGithubAccessToken();
    if (!token) {
      const error = new Error("GitHub is not connected.");
      error.statusCode = 401;
      throw error;
    }
    const safe = parseRepoPair(owner, repo);
    return githubApiRequest("PATCH", `/repos/${encodeURIComponent(safe.owner)}/${encodeURIComponent(safe.repo)}/pulls/${Number(number)}`, token, {
      state: "closed"
    });
  }

  return {
    closePullRequest,
    fetchPullRequestDetail,
    mergePullRequest,
    submitPullRequestReview
  };
}

function parseRepoPair(owner, repo) {
  const cleanOwner = String(owner || "").trim();
  const cleanRepo = String(repo || "").trim();
  if (!/^[A-Za-z0-9_.-]+$/.test(cleanOwner) || !/^[A-Za-z0-9_.-]+$/.test(cleanRepo)) {
    const error = new Error("Invalid GitHub repository.");
    error.statusCode = 400;
    throw error;
  }
  return { owner: cleanOwner, repo: cleanRepo };
}

function parsePrHandoff(body) {
  const text = String(body || "");
  const section = (title) => {
    const pattern = new RegExp(`## ${title}\\n([\\s\\S]*?)(?=\\n## |\\n---|$)`, "i");
    return (text.match(pattern)?.[1] || "").trim();
  };
  const list = (value) => value
    .split(/\r?\n/)
    .map((line) => line.replace(/^[-*]\s*/, "").trim())
    .filter((line) => line && !/^_none/i.test(line));
  const confidenceText = section("Confidence");
  return {
    tldr: section("What I did"),
    why: section("Why"),
    approach: section("Approach"),
    files_changed: list(section("Files changed(?: \\([^)]*\\))?")),
    verify: list(section("I want you to double-check")),
    tests_run: list(section("Verified")),
    tests_not_run: list(section("Not verified")),
    confidence: confidenceText ? Number(confidenceText.replace(/[^0-9.]/g, "")) / 100 : null
  };
}

function normalizeCheckState({ pr, combinedStatus, checkRuns }) {
  const states = [];
  if (combinedStatus?.state) states.push(combinedStatus.state);
  for (const run of checkRuns?.check_runs || []) {
    states.push(run.conclusion || run.status);
  }
  if (!states.length) return "unknown";
  if (states.some((state) => ["failure", "error", "cancelled", "timed_out", "action_required"].includes(state))) return "failing";
  if (states.some((state) => ["pending", "queued", "in_progress", "waiting", "requested"].includes(state))) return "pending";
  if (states.every((state) => ["success", "neutral", "skipped", "completed"].includes(state))) return "passing";
  return pr.mergeable_state || "unknown";
}

async function markPullRequestReadyForReview(token, pullRequestId) {
  if (!pullRequestId) {
    const error = new Error("GitHub did not return a pull request id.");
    error.statusCode = 502;
    throw error;
  }
  const result = await githubGraphqlRequest(token, `
    mutation MarkPullRequestReadyForReview($id: ID!) {
      markPullRequestReadyForReview(input: { pullRequestId: $id }) {
        pullRequest { number isDraft url }
      }
    }
  `, { id: pullRequestId });
  if (Array.isArray(result.errors) && result.errors.length) {
    const error = new Error(result.errors.map((item) => item.message).filter(Boolean).join("; ") || "GitHub could not mark the pull request ready for review.");
    error.statusCode = 422;
    throw error;
  }
  return result.data?.markPullRequestReadyForReview?.pullRequest || null;
}

module.exports = {
  createPullRequestService,
  parsePrHandoff,
  parseRepoPair
};
