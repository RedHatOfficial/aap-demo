"""Managed resource and AO-to-AAP wiring checks."""

from datetime import UTC, datetime
import re

try:
    from ..inventory import ManagedResourceInventory
    from ..model import CheckResult, CheckStatus, FailureClass
except ImportError:  # Direct execution via run.sh or python runner.py.
    from inventory import ManagedResourceInventory
    from model import CheckResult, CheckStatus, FailureClass


_REQUIRED_INTEGRATIONS = ("aap-demo AAP", "aap-demo MCP Server")
_EXPECTED_CREDENTIAL_TYPES = {
    "aap-demo aap token": "red hat ansible automation platform",
    "aap credential": "red hat ansible automation platform",
    "apd installer - aap admin": "apd installer credentials",
    "openshift credential": "openshift or kubernetes api bearer token",
}


def _slug(value: object) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(value).casefold()).strip("-")


def _result(check_id: str, component: str, passed: bool, summary: str, *, details=None) -> CheckResult:
    now = datetime.now(UTC).isoformat()
    return CheckResult(
        check_id=check_id,
        component=component,
        status=CheckStatus.PASS if passed else CheckStatus.FAIL,
        failure_class=None if passed else FailureClass.WIRING,
        summary=summary,
        started_at=now,
        finished_at=now,
        duration_seconds=0.0,
        details=details or {},
    )


def _project_checks(inventory) -> list[CheckResult]:
    if not inventory.projects:
        return [_result("wiring.projects", "projects", False, "no managed projects were found")]
    checks = []
    for project in inventory.projects:
        resource_id = project.get("id")
        valid = (
            project.get("scm_type") == "git"
            and bool(project.get("scm_url"))
            and bool(project.get("scm_branch"))
        )
        checks.append(_result(
            f"wiring.project.{resource_id}",
            "project",
            valid,
            "managed project has a Git SCM URL and ref" if valid else "managed project is missing a Git SCM URL or ref",
            details={"resource_id": resource_id, "name": project.get("name")},
        ))
    return checks


def _credential_checks(inventory) -> list[CheckResult]:
    valid = bool(inventory.credentials) and all(item.get("credential_type_name") for item in inventory.credentials)
    return [_result(
        "wiring.credentials",
        "credentials",
        valid,
        "managed credentials and their types are present" if valid else "managed credentials or credential types are missing",
        details={"resource_ids": [item.get("id") for item in inventory.credentials]},
    )]


def _job_template_checks(inventory) -> list[CheckResult]:
    if not inventory.job_templates:
        return [_result("wiring.job-templates", "job_templates", False, "no managed job templates were found")]
    projects = {item.get("id") for item in inventory.projects}
    execution_environments = {item.get("id") for item in inventory.execution_environments}
    credentials = {item.get("id"): item for item in inventory.credentials}
    checks = []
    for template in inventory.job_templates:
        resource_id = template.get("id")
        project_ok = template.get("project_id") in projects
        ee_id = template.get("execution_environment_id")
        ee_ok = ee_id is None or ee_id in execution_environments
        launch_ok = template.get("can_start") is True
        valid = project_ok and ee_ok and launch_ok
        checks.append(_result(
            f"wiring.job-template.{resource_id}",
            "job_template",
            valid,
            "job template project, execution environment, and launch permission are wired" if valid else "job template project, execution environment, or launch permission is missing",
            details={"resource_id": resource_id, "name": template.get("name"), "project_id": template.get("project_id"), "execution_environment_id": ee_id},
        ))
        credential_ids = template.get("credential_ids", [])
        attached_credentials = [credentials.get(credential_id) for credential_id in credential_ids]
        credential_types_ok = all(
            credential
            and credential.get("credential_type_name")
            and _EXPECTED_CREDENTIAL_TYPES.get(str(credential.get("name", "")).casefold(), str(credential.get("credential_type_name")).casefold())
            == str(credential.get("credential_type_name")).casefold()
            for credential in attached_credentials
        )
        credentials_ok = bool(credential_ids) and len(attached_credentials) == len(credential_ids) and credential_types_ok
        checks.append(_result(
            f"wiring.job-template.{resource_id}.credentials",
            "job_template",
            credentials_ok,
            "job template credentials are present, resolvable, and correctly typed" if credentials_ok else "job template has missing, dangling, or incorrectly typed credentials",
            details={"resource_id": resource_id, "name": template.get("name"), "credential_ids": credential_ids},
        ))
    return checks


def _integration_checks(inventory) -> list[CheckResult]:
    integrations = {str(item.get("name", "")).casefold(): item for item in inventory.ao_integrations}
    checks = []
    for name in _REQUIRED_INTEGRATIONS:
        integration = integrations.get(name.casefold())
        valid = bool(integration) and bool(integration.get("endpoint")) and integration.get("enabled") is not False and bool(integration.get("credential_id"))
        checks.append(_result(
            f"wiring.integration.{_slug(name)}",
            "ao_integration",
            valid,
            f"{name} has an enabled endpoint and credential" if valid else f"{name} integration, endpoint, or credential is missing",
            details={"resource_id": integration.get("id") if integration else None, "name": name},
        ))
    return checks


def _workflow_checks(inventory) -> list[CheckResult]:
    if not inventory.ao_workflows:
        return [_result("wiring.workflows", "ao_workflows", False, "no managed AO workflows were found")]
    template_ids = {item.get("id") for item in inventory.job_templates}
    integration_ids = {item.get("id") for item in inventory.ao_integrations}
    checks = []
    for workflow in inventory.ao_workflows:
        nodes = workflow.get("aap_job_template_nodes", [])
        valid = bool(nodes) and all(
            node.get("job_template_id") in template_ids
            and node.get("integration_id") in integration_ids
            and bool(node.get("credential_id"))
            for node in nodes
        )
        resource_id = workflow.get("id")
        checks.append(_result(
            f"wiring.workflow.{resource_id}",
            "ao_workflow",
            valid,
            "workflow AAP job-template bindings are present" if valid else "workflow has missing AAP job-template, integration, or credential bindings",
            details={"resource_id": resource_id, "name": workflow.get("name")},
        ))
    return checks


def run(inventory: ManagedResourceInventory) -> list[CheckResult]:
    """Validate non-mutating AAP/AO resource relationships and permissions."""
    return [
        *_project_checks(inventory),
        *_credential_checks(inventory),
        *_job_template_checks(inventory),
        *_integration_checks(inventory),
        *_workflow_checks(inventory),
    ]
