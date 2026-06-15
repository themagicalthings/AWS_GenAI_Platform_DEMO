"""Repository-contract guardrail tests.

These run in CI today, before the application services exist, so the Python
job has real coverage and the repo's structural invariants are protected.
Real unit tests for the Lambda tool, agent, and UI arrive in plan phases 4-6.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE_MODULES = ("network", "security", "storage")


def test_terraform_root_files_exist():
    for name in ("backend.tf", "providers.tf", "variables.tf", "main.tf", "dev.tfvars"):
        path = ROOT / "terraform" / name
        assert path.is_file(), f"missing terraform/{name}"


def test_core_modules_exist():
    for module in CORE_MODULES:
        path = ROOT / "terraform" / "modules" / module / "main.tf"
        assert path.is_file(), f"missing terraform module: {module}"


def test_each_core_module_has_terraform_tests():
    for module in CORE_MODULES:
        test_dir = ROOT / "terraform" / "modules" / module / "tests"
        found = list(test_dir.glob("*.tftest.hcl"))
        assert found, f"module {module} has no terraform tests"


def test_design_and_plan_are_committed():
    spec = ROOT / "docs/superpowers/specs/2026-06-13-knowledge-assistant-platform-design.md"
    plan = ROOT / "docs/superpowers/plans/2026-06-13-knowledge-assistant-platform.md"
    assert spec.is_file(), "design spec missing"
    assert plan.is_file(), "implementation plan missing"
