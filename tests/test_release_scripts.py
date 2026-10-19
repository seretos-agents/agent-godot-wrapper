"""Driving tests for the release-changelog scripts (epic #9 / package #9).

Covers, per the plan (`.adev/9-1/plan.md`):
  - R1: `.github/scripts/prev-release-tag.sh` -- strict-semver previous-tag resolution.
  - R2: `.github/scripts/release-preflight.sh` -- fails before any remote side effect.
  - R3: `.github/scripts/marketplace-payload.sh` -- hostile-changelog round trip and the
        optional `changelog` key / `repository_dispatch` 10-key payload limit.

None of the three scripts exist yet at the time these tests are written (phase=tests):
every test below is expected to fail because `.github/scripts/<name>.sh` is missing
(bash exit 127, "No such file or directory"), not for any other reason.

Run with: `python -m pytest tests/test_release_scripts.py -v`
"""
from __future__ import annotations

import json
import os
import platform
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / ".github" / "scripts"
PLUGIN = "agent-godot-wrapper"

BASH_EXE = r"C:\Program Files\Git\bin\bash.exe" if platform.system() == "Windows" else "bash"

# Global git config overrides so a machine-wide commit.gpgsign=true (or similar)
# never blocks these throwaway local repos on a passphrase prompt.
_GIT_SAFE_CONFIG = ["-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"]


def _git(args, cwd=None, check=True):
    result = subprocess.run(
        ["git", *_GIT_SAFE_CONFIG, *args],
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"git {' '.join(args)} failed (cwd={cwd}):\n{result.stdout}\n{result.stderr}"
        )
    return result


def run_script(name, args=(), cwd=None, env=None, timeout=30):
    """Invoke a `.github/scripts/<name>` under the platform's bash."""
    script_path = SCRIPTS_DIR / name
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    return subprocess.run(
        [BASH_EXE, str(script_path), *args],
        cwd=str(cwd) if cwd else None,
        env=full_env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=timeout,
    )


def ls_remote_tags(bare_path):
    return _git(["ls-remote", "--tags", str(bare_path)]).stdout


def make_tagged_repo(tmp_path, tags):
    """A plain repo (no remote) with the given tags on its single commit."""
    work = tmp_path / "repo"
    _git(["init", "-b", "main", str(work)])
    _git(["config", "user.name", "Test User"], cwd=work)
    _git(["config", "user.email", "test@example.com"], cwd=work)
    (work / "README.md").write_text("test\n", encoding="utf-8")
    _git(["add", "."], cwd=work)
    _git(["commit", "-m", "init"], cwd=work)
    for tag in tags:
        _git(["tag", tag], cwd=work)
    return work


def make_repo_with_origin(tmp_path):
    """A repo whose `origin` remote is a local bare repo, main pushed and up to date."""
    bare = tmp_path / "origin.git"
    _git(["init", "--bare", "-b", "main", str(bare)])
    work = tmp_path / "work"
    _git(["init", "-b", "main", str(work)])
    _git(["config", "user.name", "Test User"], cwd=work)
    _git(["config", "user.email", "test@example.com"], cwd=work)
    (work / "README.md").write_text("test\n", encoding="utf-8")
    _git(["add", "."], cwd=work)
    _git(["commit", "-m", "init"], cwd=work)
    _git(["remote", "add", "origin", str(bare)], cwd=work)
    _git(["push", "origin", "main"], cwd=work)
    return work, bare


def push_tag(work, tag, sha=None):
    args = ["tag", tag] + ([sha] if sha else [])
    _git(args, cwd=work)
    _git(["push", "origin", tag], cwd=work)


# ---------------------------------------------------------------------------
# R1 -- prev-release-tag.sh (driving-test)
# ---------------------------------------------------------------------------

R1_TAGS = [
    f"{PLUGIN}--v0.0.1",
    f"{PLUGIN}--v0.1.0-rc.2",
    f"{PLUGIN}--v0.1.0-rc.10",
    f"src/{PLUGIN}--v0.9.9",           # marker tag: must never be treated as a release tag
    "other-plugin--v0.5.0",           # foreign plugin: must be excluded
    f"{PLUGIN}--v01.0.0",             # malformed (leading zero): must be excluded
]


@pytest.fixture
def r1_repo(tmp_path):
    return make_tagged_repo(tmp_path, R1_TAGS)


def test_prev_tag_picks_highest_prerelease_below_release(r1_repo):
    result = run_script("prev-release-tag.sh", [PLUGIN, "0.1.0"], cwd=r1_repo)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip() == f"{PLUGIN}--v0.1.0-rc.10"


def test_prev_tag_orders_rc2_below_rc10_and_excludes_self(r1_repo):
    # 0.1.0-rc.10 must not match itself, and must rank rc.2 < rc.10 numerically
    # (not lexically, where "10" < "2").
    result = run_script("prev-release-tag.sh", [PLUGIN, "0.1.0-rc.10"], cwd=r1_repo)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip() == f"{PLUGIN}--v0.1.0-rc.2"


def test_prev_tag_excludes_marker_foreign_and_malformed_tags(r1_repo):
    # If src/<PLUGIN>--v0.9.9, other-plugin--v0.5.0, or the leading-zero
    # v01.0.0 tag were wrongly matched, 0.9.9 would outrank 0.1.0-rc.10.
    result = run_script("prev-release-tag.sh", [PLUGIN, "1.0.0"], cwd=r1_repo)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip() == f"{PLUGIN}--v0.1.0-rc.10"


def test_prev_tag_no_lower_tag_prints_nothing(r1_repo):
    # 0.0.1 equals the lowest existing tag, which must exclude itself -> no match.
    result = run_script("prev-release-tag.sh", [PLUGIN, "0.0.1"], cwd=r1_repo)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip() == ""


def test_prev_tag_excludes_malformed_leading_zero_tag_from_selection(r1_repo):
    # A query of 1.0.0 (used above) can't distinguish "v01.0.0 correctly
    # excluded by grammar" from "v01.0.0 loosely parsed as 1.0.0 and then
    # excluded only because it ties the query" -- both give the same
    # answer, since equality also excludes. Querying above it (2.0.0) does
    # distinguish: a parser that accepts the leading zero and reads
    # v01.0.0 as plain 1.0.0 would select it here, since 1.0.0 outranks
    # every correctly-grammared tag in the fixture.
    result = run_script("prev-release-tag.sh", [PLUGIN, "2.0.0"], cwd=r1_repo)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip() == f"{PLUGIN}--v0.1.0-rc.10"


# -- Additional edge-case coverage (not required to demonstrate RED individually) --

@pytest.mark.parametrize(
    "bad_version",
    ["1.0", "01.0.0", "1.0.0-", "1.0.0+build", "1.0.0-rc..1"],
)
def test_prev_tag_rejects_invalid_semver(tmp_path, bad_version):
    work = make_tagged_repo(tmp_path, [])
    result = run_script("prev-release-tag.sh", [PLUGIN, bad_version], cwd=work)
    assert result.returncode == 2, result.stdout + result.stderr


def test_prev_tag_precedence_ordering_alpha_through_release(tmp_path):
    tags = [
        f"{PLUGIN}--v1.0.0-alpha",
        f"{PLUGIN}--v1.0.0-alpha.1",
        f"{PLUGIN}--v1.0.0-beta",
        f"{PLUGIN}--v1.0.0-rc.1",
        f"{PLUGIN}--v1.0.0",
    ]
    work = make_tagged_repo(tmp_path, tags)

    result = run_script("prev-release-tag.sh", [PLUGIN, "2.0.0"], cwd=work)
    assert result.stdout.strip() == f"{PLUGIN}--v1.0.0"

    result = run_script("prev-release-tag.sh", [PLUGIN, "1.0.0"], cwd=work)
    assert result.stdout.strip() == f"{PLUGIN}--v1.0.0-rc.1"

    result = run_script("prev-release-tag.sh", [PLUGIN, "1.0.0-rc.1"], cwd=work)
    assert result.stdout.strip() == f"{PLUGIN}--v1.0.0-beta"

    result = run_script("prev-release-tag.sh", [PLUGIN, "1.0.0-beta"], cwd=work)
    assert result.stdout.strip() == f"{PLUGIN}--v1.0.0-alpha.1"

    result = run_script("prev-release-tag.sh", [PLUGIN, "1.0.0-alpha.1"], cwd=work)
    assert result.stdout.strip() == f"{PLUGIN}--v1.0.0-alpha"


# ---------------------------------------------------------------------------
# R2 -- release-preflight.sh (driving-test)
# ---------------------------------------------------------------------------

def _preflight_env(output_file):
    return {"DEFAULT_BRANCH": "main", "GITHUB_OUTPUT": str(output_file)}


def test_preflight_rejects_when_marker_tag_already_exists(tmp_path):
    # Plan R2 case (a): the src/<TAG> marker for the version being released
    # is present on the remote -> exit 1, output names it. This is the case
    # a re-run would hit trying to push a marker that already exists; it is
    # distinct from the plain-<TAG>-exists case covered just below.
    work, bare = make_repo_with_origin(tmp_path)
    sha = _git(["rev-parse", "HEAD"], cwd=work).stdout.strip()
    push_tag(work, f"src/{PLUGIN}--v0.2.0", sha)
    before = ls_remote_tags(bare)
    output_file = tmp_path / "github_output"
    output_file.write_text("", encoding="utf-8")

    result = run_script(
        "release-preflight.sh", [PLUGIN, "0.2.0"], cwd=work, env=_preflight_env(output_file)
    )

    assert result.returncode != 0
    assert f"src/{PLUGIN}--v0.2.0" in (result.stdout + result.stderr)
    assert ls_remote_tags(bare) == before
    assert output_file.read_text(encoding="utf-8") == ""


def test_preflight_rejects_when_tag_already_exists(tmp_path):
    work, bare = make_repo_with_origin(tmp_path)
    push_tag(work, f"{PLUGIN}--v0.2.0")
    before = ls_remote_tags(bare)
    output_file = tmp_path / "github_output"
    output_file.write_text("", encoding="utf-8")

    result = run_script(
        "release-preflight.sh", [PLUGIN, "0.2.0"], cwd=work, env=_preflight_env(output_file)
    )

    assert result.returncode != 0
    assert f"{PLUGIN}--v0.2.0" in (result.stdout + result.stderr)
    assert ls_remote_tags(bare) == before
    assert output_file.read_text(encoding="utf-8") == ""


def test_preflight_prints_bootstrap_commands_when_marker_missing(tmp_path):
    work, bare = make_repo_with_origin(tmp_path)
    push_tag(work, f"{PLUGIN}--v0.1.0")
    before = ls_remote_tags(bare)
    output_file = tmp_path / "github_output"
    output_file.write_text("", encoding="utf-8")

    result = run_script(
        "release-preflight.sh", [PLUGIN, "0.2.0"], cwd=work, env=_preflight_env(output_file)
    )

    assert result.returncode != 0
    combined = result.stdout + result.stderr
    assert f"git tag src/{PLUGIN}--v0.1.0 " in combined
    assert f"git push origin src/{PLUGIN}--v0.1.0" in combined
    assert ls_remote_tags(bare) == before
    assert output_file.read_text(encoding="utf-8") == ""


# -- Additional edge-case coverage (not required to demonstrate RED individually) --

def test_preflight_first_release_succeeds_with_empty_prev_tag(tmp_path):
    work, bare = make_repo_with_origin(tmp_path)
    output_file = tmp_path / "github_output"
    output_file.write_text("", encoding="utf-8")

    result = run_script(
        "release-preflight.sh", [PLUGIN, "0.1.0"], cwd=work, env=_preflight_env(output_file)
    )

    assert result.returncode == 0, result.stdout + result.stderr
    head_sha = _git(["rev-parse", "HEAD"], cwd=work).stdout.strip()
    out = output_file.read_text(encoding="utf-8")
    assert "prev_tag=\n" in out or out.rstrip("\n").endswith("prev_tag=")
    assert f"main_sha={head_sha}" in out


def test_preflight_reports_prev_tag_when_marker_present(tmp_path):
    work, bare = make_repo_with_origin(tmp_path)
    push_tag(work, f"{PLUGIN}--v0.1.0")
    sha = _git(["rev-parse", "HEAD"], cwd=work).stdout.strip()
    push_tag(work, f"src/{PLUGIN}--v0.1.0", sha)
    output_file = tmp_path / "github_output"
    output_file.write_text("", encoding="utf-8")

    result = run_script(
        "release-preflight.sh", [PLUGIN, "0.2.0"], cwd=work, env=_preflight_env(output_file)
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert f"prev_tag={PLUGIN}--v0.1.0" in output_file.read_text(encoding="utf-8")


def test_preflight_rejects_invalid_version(tmp_path):
    work, bare = make_repo_with_origin(tmp_path)
    output_file = tmp_path / "github_output"
    output_file.write_text("", encoding="utf-8")

    result = run_script(
        "release-preflight.sh", [PLUGIN, "not-a-version"], cwd=work, env=_preflight_env(output_file)
    )

    assert result.returncode != 0
    assert output_file.read_text(encoding="utf-8") == ""


def test_preflight_rejects_head_behind_default_branch(tmp_path):
    work, bare = make_repo_with_origin(tmp_path)
    # Advance origin/main past work's HEAD via an independent clone, without
    # updating work's own checkout -- simulating a stale/non-tip HEAD.
    other = tmp_path / "other-clone"
    _git(["clone", str(bare), str(other)])
    _git(["config", "user.name", "Test User"], cwd=other)
    _git(["config", "user.email", "test@example.com"], cwd=other)
    (other / "extra.txt").write_text("x\n", encoding="utf-8")
    _git(["add", "."], cwd=other)
    _git(["commit", "-m", "extra"], cwd=other)
    _git(["push", "origin", "main"], cwd=other)

    before = ls_remote_tags(bare)
    output_file = tmp_path / "github_output"
    output_file.write_text("", encoding="utf-8")

    result = run_script(
        "release-preflight.sh", [PLUGIN, "0.1.0"], cwd=work, env=_preflight_env(output_file)
    )

    assert result.returncode != 0
    assert ls_remote_tags(bare) == before
    assert output_file.read_text(encoding="utf-8") == ""


# ---------------------------------------------------------------------------
# R3 -- marketplace-payload.sh (driving-test)
# ---------------------------------------------------------------------------

BASE_PAYLOAD_ENV = {
    "NAME": PLUGIN,
    "DESC": 'Wraps the "Godot MCP Toolkit" bridge with a skill.',
    "REPO": "seretos-agents/agent-godot-wrapper",
    "VERSION": "0.2.0",
    "TAG": f"{PLUGIN}--v0.2.0",
}

HOSTILE_CHANGELOG = (
    "  leading and trailing spaces  \n"
    '"quoted" \\backslash\\\n'
    "line with CRLF\r\n"
    "\ttabbed line\n"
    "$(id) `backticks` ${HOME}\n"
    "EOF\n"
    "path like /usr/bin:/tmp and C:\\x\n"
    "<script>alert(1)</script>\n"
    "unicode \u00fc and emoji \U0001F389\n"
    "trailing newline above must survive too  \n"
)


def run_payload(env, cwd=None):
    full_env = dict(BASE_PAYLOAD_ENV)
    full_env.update(env)
    return run_script("marketplace-payload.sh", cwd=cwd, env=full_env)


def test_payload_roundtrips_hostile_changelog_byte_for_byte():
    result = run_payload({"CHANGELOG": HOSTILE_CHANGELOG})
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    assert payload["client_payload"]["changelog"] == HOSTILE_CHANGELOG
    # A quote-bearing DESC must also round-trip, not just CHANGELOG.
    assert payload["client_payload"]["description"] == BASE_PAYLOAD_ENV["DESC"]


def test_payload_omits_empty_changelog_key():
    result = run_payload({"CHANGELOG": ""})
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    client_payload = payload["client_payload"]

    assert "changelog" not in client_payload
    assert payload["event_type"] == "plugin-release"
    assert client_payload["name"] == BASE_PAYLOAD_ENV["NAME"]
    assert client_payload["description"] == BASE_PAYLOAD_ENV["DESC"]
    assert client_payload["repo"] == BASE_PAYLOAD_ENV["REPO"]
    assert client_payload["category"] == "skill"
    assert client_payload["version"] == BASE_PAYLOAD_ENV["VERSION"]
    assert client_payload["ref"] == BASE_PAYLOAD_ENV["TAG"]
    assert client_payload["icon"] == (
        f"https://raw.githubusercontent.com/{BASE_PAYLOAD_ENV['REPO']}/"
        f"{BASE_PAYLOAD_ENV['TAG']}/assets/icon.png"
    )
    assert client_payload["description_url"] == (
        f"https://raw.githubusercontent.com/{BASE_PAYLOAD_ENV['REPO']}/"
        f"{BASE_PAYLOAD_ENV['TAG']}/description.md"
    )
    assert client_payload["tags"] == ["godot", "game-engine", "3d"]
    assert len(client_payload) == 9


def test_payload_omits_changelog_key_when_unset(monkeypatch):
    # Distinct from the empty-string case above: CHANGELOG is not merely ""
    # but absent from the environment entirely. A filter comparing
    # `$ENV.CHANGELOG != ""` (rather than `($ENV.CHANGELOG // "") != ""`)
    # would emit `"changelog": null` here instead of omitting the key.
    monkeypatch.delenv("CHANGELOG", raising=False)
    result = run_payload({})
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    assert "changelog" not in payload["client_payload"]


# -- Additional edge-case coverage (not required to demonstrate RED individually) --

def test_payload_key_count_at_repository_dispatch_limit_when_changelog_present():
    result = run_payload({"CHANGELOG": "some release notes"})
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    assert len(payload["client_payload"]) == 10


@pytest.mark.parametrize("missing_var", ["NAME", "DESC", "REPO", "VERSION", "TAG"])
def test_payload_fails_when_required_var_missing(missing_var):
    result = run_payload({missing_var: ""})
    assert result.returncode != 0
