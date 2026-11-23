// Deterministic highlights for Arx pull requests (DEV-1281). Every rule warns or leaves a message;
// none fails the check. The workflow (.github/workflows/danger.yml) runs the default branch's copy
// of this file on pull_request_target and never runs the pull request's code; the dependency table
// comes from Scripts/dependency_diff.py, run on the pull request's commits as data.
//
// Locally, from the repository root, against main:
//   npm ci --ignore-scripts --prefix .github/danger
//   .github/danger/node_modules/.bin/danger local --base main --dangerfile .github/danger/dangerfile.js
// The rules that need the pull request's text (evidence, the manual) are skipped there.
//
// danger, warn, message, markdown and schedule are globals Danger provides.

const childProcess = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

const DEPENDENCY_LABEL = { name: "new dependency", color: "d93f0b", description: "Adds, removes or moves a dependency" }
const LARGE_LINES = 1500
const LARGE_FILES = 60

const pr = danger.github ? danger.github.pr : null
const body = pr ? pr.body || "" : null
const created = danger.git.created_files
const modified = danger.git.modified_files
const deleted = danger.git.deleted_files
const touched = [...new Set([...created, ...modified, ...deleted])].sort()

const under = (...prefixes) => touched.filter((file) => prefixes.some((prefix) => file.startsWith(prefix)))
const list = (files, limit = 8) =>
  files.slice(0, limit).map((file) => `\`${file}\``).join(", ") + (files.length > limit ? ` and ${files.length - limit} more` : "")

// Dependencies: every Package.resolved, the Package.swift manifests, THIRD_PARTY_NOTICES.md and the forks.
function dependencyReport() {
  const ready = process.env.ARX_DEPENDENCIES_JSON
  if (ready) return JSON.parse(fs.readFileSync(ready, "utf8"))
  // Local run: compare the working tree with main.
  const output = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "arx-danger-")), "dependencies.json")
  childProcess.execFileSync("python3", ["-m", "Scripts.dependency_diff", "--json", output], { stdio: ["ignore", "ignore", "inherit"] })
  return JSON.parse(fs.readFileSync(output, "utf8"))
}

function dependencyTable(report) {
  const ready = process.env.ARX_DEPENDENCIES_MARKDOWN
  if (ready) return fs.readFileSync(ready, "utf8")
  const rows = report.changes.map(
    (change) => `| \`${change.name}\` | ${change.change} | ${change.before || "–"} | ${change.after || "–"} | ${change.source} |`
  )
  return ["| Dependency | Change | Before | After | Where |", "| --- | --- | --- | --- | --- |", ...rows].join("\n")
}

schedule(async () => {
  const report = dependencyReport()
  if (report.changes.length === 0) return
  const added = report.added.length ? ` New: ${report.added.map((name) => `\`${name}\``).join(", ")}.` : ""
  warn(
    `This pull request adds, removes or moves dependencies (labelled \`${DEPENDENCY_LABEL.name}\`).${added} ` +
      "A maintainer checks each one's licence and source before merging."
  )
  markdown(`### Dependencies\n\n${dependencyTable(report)}`)
  const sources = new Set(report.changes.map((change) => change.source))
  if ((sources.has("pin") || sources.has("manifest") || sources.has("fork")) && !sources.has("notice")) {
    warn("Dependencies changed but `THIRD_PARTY_NOTICES.md` didn't. Update its table and run `make credits`.")
  }
  if (pr) {
    await danger.github.utils.createOrAddLabel(DEPENDENCY_LABEL)
  }
})

// The engine: only an engine build proves these.
const engine = under("Packages/engine/Native/", "Scripts/engine/")
if (engine.length) {
  message(
    `Changes the engine (${list(engine)}), so it needs an engine build: \`make engine-build\` and the smokes, ` +
      "or the *Engine build* workflow, which only builds this repository's own branches. " +
      "`make engine-check` is compile proof for the native bridge only."
  )
}

// Views and AppUI: a picture or a recording in the description.
const views = touched.filter(
  (file) =>
    !deleted.includes(file) &&
    (file.startsWith("Packages/design-system/Sources/AppUI/") ||
      (file.startsWith("Packages/") && file.includes("/Sources/") && (/View\.swift$/.test(file) || /\/Views?\//.test(file))))
)
const evidence = /!\[[^\]]*\]\(|<img\b|<video\b|user-attachments\/assets\/|\.(png|jpe?g|gif|webp|heic|mov|mp4|webm)\b/i
if (views.length && body !== null && !evidence.test(body)) {
  warn(
    `Changes what Arx shows (${list(views)}) but the description has no image or video. ` +
      "Add screenshots or a recording, before and after where something changed."
  )
}

// User-visible changes: the manual in capturecontext/arx-browser-manual.
const userVisible = [
  ...views,
  ...touched.filter((file) =>
    /\.xcstrings$/.test(file) ||
    file.startsWith("Packages/features/Sources/SettingsFeature/") ||
    file.startsWith("Packages/services/Sources/AgentToolsClient/Skill/") ||
    /BrowserCommand[^/]*\.swift$/.test(file) ||
    /FeatureFlag[^/]*\.swift$/.test(file)
  ),
]
if (userVisible.length && body !== null && !/\bmanual\b/i.test(body)) {
  warn(
    "Looks user-visible, but the description doesn't mention the manual. Link the change to " +
      "[arx-browser-manual](https://github.com/capturecontext/arx-browser-manual), or say that no manual change is needed."
  )
}

// Very large pull requests, without lock files and images.
schedule(async () => {
  const counted = touched.filter((file) => !/(^|\/)(Package\.resolved|package-lock\.json)$|\.(png|jpe?g|gif|pdf)$/i.test(file))
  const lines = await danger.git.linesOfCode("**/*")
  const lockLines = await danger.git.linesOfCode("{**/Package.resolved,**/package-lock.json}")
  const changed = (lines || 0) - (lockLines || 0)
  if (changed > LARGE_LINES || counted.length > LARGE_FILES) {
    warn(
      `A large pull request: ${changed} changed lines in ${counted.length} files. ` +
        "Smaller ones get reviewed sooner; split it if the parts stand alone."
    )
  }
})

// CI and agent instructions.
const ci = under(".github/", "Scripts/dependency_diff.py")
if (ci.length) {
  warn(
    `Changes CI (${list(ci)}). A maintainer reviews these by hand. Workflows triggered by pull_request_target, ` +
      "issue_comment and this Danger check run the default branch's copy, so a change here takes effect after it merges."
  )
}
const agents = under(".agents/", "AGENTS.md")
if (agents.length) {
  warn(`Changes agent instructions (${list(agents)}). Agents and the review bot read these; check them for instructions they shouldn't follow.`)
}
