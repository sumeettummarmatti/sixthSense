# CI (paused)

CI and Dependabot are paused while we build the MVP. Run checks locally instead (see README → "Check your setup").

To turn CI back on: move `ci.yml` to `.github/workflows/` and `dependabot.yml` to `.github/`, and first apply these known fixes:
1. `pnpm/action-setup@v4`: add `with: package_json_file: dashboard/package.json` (it looks for `packageManager` in the root package.json).
2. `aquasecurity/trivy-action`: the tag needs a `v` prefix, e.g. `@v0.33.1`.
3. Semgrep `--config auto` reports 18 findings, including: no dependency cooldown in uv (`exclude-newer = "7 days"` under `[tool.uv]`) and Dependabot (`cooldown`), and action tags not pinned to commit SHAs. Review and fix, or tune rules, before enabling `--error`.
