"""Managed resource and AO-to-AAP wiring checks."""

import re

try:
    from ..check_timing import CheckTimer
    from ..inventory import ManagedResourceInventory
    from ..model import CheckResult, CheckStatus, FailureClass
except ImportError:  # Direct execution via run.sh or python runner.py.
    from check_timing import CheckTimer
    from inventory import ManagedResourceInventory
    from model import CheckResult, CheckStatus, FailureClass


_REQUIRED_INTEGRATIONS = ("aap-demo AAP", "aap-demo MCP Server")
_EXPECTED_CREDENTIAL_TYPES = {
    "aap-demo aap token": "red hat ansible automation platform",
    "aap credential": "red hat ansible automation platform",
    "apd installer - aap admin": "apd installer credentials",
    "openshift credential": "openshift or kubernetes api bearer token",
}
_EXPECTED_PROJECTS = {
    "aap orchestrator demos": {
        "url": "https://github.com/ansible-tmm/aap-orchestrator-demos",
        "ref": "abcc1a1482a",
        "revision_prefix": "abcc1a1482a",
    },
    "aap demo control plane": {
        "url": "https://github.com/redhatofficial/aap-demo",
        "immutable": True,
    },
    "apd bootstrap project": {
        "url": "https://github.com/ansible/product-demos",
        "immutable": True,
    },
    "ansible product demos": {
        "url": "https://github.com/ansible/product-demos",
        "immutable": True,
    },
}
_SAFE_TEMPLATE_CONTRACTS = {
    "aap-demo acceptance | ao read-only diagnostic": {
        "project": "AAP Demo Control Plane",
        "playbook": "addons/ao/playbooks/acceptance-read-only.yml",
        "execution_environment": "Product Demos EE",
        "ask_variables_on_launch": True,
    },
    "aap-demo acceptance | product demos read-only diagnostic": {
        "project": "APD Bootstrap Project",
        "playbook": "acceptance-read-only.yml",
        "execution_environment": "Product Demos EE",
        "ask_variables_on_launch": True,
    },
}
_EXPECTED_AO_INTEGRATIONS = {
    "aap-demo aap": {
        "credential": "aap-demo AAP Token",
        "type": "ansible_automation_platform",
    },
    "aap-demo mcp server": {
        "credential": "aap-demo MCP Token",
        "type": "mcp_server",
    },
}
_IMMUTABLE_REF = re.compile(r"^[0-9a-f]{40,64}$")


def _slug(value: object) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(value).casefold()).strip("-")


def _result(
    check_id: str,
    component: str,
    passed: bool,
    summary: str,
    *,
    details=None,
    timer: CheckTimer | None = None,
) -> CheckResult:
    started_at, finished_at, duration_seconds = (timer or CheckTimer.start()).finish()
    return CheckResult(
        check_id=check_id,
        component=component,
        status=CheckStatus.PASS if passed else CheckStatus.FAIL,
        failure_class=None if passed else FailureClass.WIRING,
        summary=summary,
        started_at=started_at,
        finished_at=finished_at,
        duration_seconds=duration_seconds,
        details=details or {},
    )


def _project_checks(inventory) -> list[CheckResult]:
    if not inventory.projects:
        return [_result("wiring.projects", "projects", False, "no managed projects were found")]
    checks = []
    for project in inventory.projects:
        resource_id = project.get("id")
        expected = _EXPECTED_PROJECTS.get(str(project.get("name", "")).casefold())
        branch = str(project.get("scm_branch", ""))
        revision = str(project.get("scm_revision", ""))
        observed_url = str(project.get("scm_url", "")).rstrip("/").removesuffix(".git").casefold()
        ref_ok = False
        if expected and expected.get("immutable"):
            ref_ok = bool(
                _IMMUTABLE_REF.fullmatch(branch)
                and revision == branch
            )
        elif expected:
            ref_ok = branch == expected.get("ref") and revision.startswith(
                str(expected.get("revision_prefix", ""))
            )
        valid = bool(
            expected
            and project.get("scm_type") == "git"
            and observed_url == expected["url"]
            and ref_ok
            and project.get("scm_update_on_launch") is False
        )
        checks.append(_result(
            f"wiring.project.{resource_id}",
            "project",
            valid,
            "managed project matches its immutable repository and revision contract" if valid else "managed project repository or immutable revision does not match its addon contract",
            details={"resource_id": resource_id, "name": project.get("name"), "scm_branch": branch, "scm_revision": revision},
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
    execution_environments_by_id = {
        item.get("id"): item for item in inventory.execution_environments
    }
    credentials = {item.get("id"): item for item in inventory.credentials}
    checks = []
    for template in inventory.job_templates:
        resource_id = template.get("id")
        project_ok = template.get("project_id") in projects
        ee_id = template.get("execution_environment_id")
        ee_ok = ee_id is None or ee_id in execution_environments
        launch_ok = template.get("can_start") is True
        safe_contract = _SAFE_TEMPLATE_CONTRACTS.get(
            str(template.get("name", "")).casefold()
        )
        exact_ok = True
        if safe_contract:
            exact_ok = (
                template.get("project_name") == safe_contract["project"]
                and template.get("playbook") == safe_contract["playbook"]
                and execution_environments_by_id.get(ee_id, {}).get("name")
                == safe_contract["execution_environment"]
                and template.get("ask_variables_on_launch")
                is safe_contract["ask_variables_on_launch"]
            )
        valid = project_ok and ee_ok and launch_ok and bool(template.get("playbook")) and exact_ok
        checks.append(_result(
            f"wiring.job-template.{resource_id}",
            "job_template",
            valid,
            "job template matches its project, playbook, execution environment, and launch contract" if valid else "job template project, playbook, execution environment, or launch contract is invalid",
            details={"resource_id": resource_id, "name": template.get("name"), "project_id": template.get("project_id"), "playbook": template.get("playbook"), "execution_environment_id": ee_id},
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
        expected_credential_names = (
            {"apd installer - aap admin"}
            if str(template.get("name", "")).casefold().startswith("apd | install")
            else set()
        )
        attached_names = {
            str(credential.get("name", "")).casefold()
            for credential in attached_credentials
            if credential
        }
        credentials_ok = (
            len(attached_credentials) == len(credential_ids)
            and credential_types_ok
            and (
                attached_names == expected_credential_names
                if safe_contract or expected_credential_names
                else True
            )
        )
        checks.append(_result(
            f"wiring.job-template.{resource_id}.credentials",
            "job_template",
            credentials_ok,
            "job template credential associations match its explicit contract" if credentials_ok else "job template has missing, unexpected, dangling, or incorrectly typed credentials",
            details={"resource_id": resource_id, "name": template.get("name"), "credential_ids": credential_ids},
        ))
    return checks


def _integration_checks(inventory) -> list[CheckResult]:
    integrations = {str(item.get("name", "")).casefold(): item for item in inventory.ao_integrations}
    checks = []
    ao_credentials = {item.get("id"): item for item in inventory.ao_credentials}
    for name in _REQUIRED_INTEGRATIONS:
        integration = integrations.get(name.casefold())
        expected = _EXPECTED_AO_INTEGRATIONS[name.casefold()]
        credential = ao_credentials.get(integration.get("credential_id")) if integration else None
        valid = bool(
            integration
            and bool(integration.get("endpoint"))
            and integration.get("enabled") is not False
            and integration.get("integration_type") == expected["type"]
            and credential
            and credential.get("name") == expected["credential"]
        )
        checks.append(_result(
            f"wiring.integration.{_slug(name)}",
            "ao_integration",
            valid,
            f"{name} has its expected endpoint and effective AO credential" if valid else f"{name} integration type, endpoint, or effective AO credential is invalid",
            details={"resource_id": integration.get("id") if integration else None, "credential_id": integration.get("credential_id") if integration else None, "name": name},
        ))
    return checks


def _workflow_checks(inventory) -> list[CheckResult]:
    if not inventory.ao_workflows:
        return [_result("wiring.workflows", "ao_workflows", False, "no managed AO workflows were found")]
    template_ids = {item.get("id") for item in inventory.job_templates}
    integration_ids = {item.get("id") for item in inventory.ao_integrations}
    aap_integration = next(
        (
            item for item in inventory.ao_integrations
            if str(item.get("name", "")).casefold() == "aap-demo aap"
        ),
        None,
    )
    expected_integration_id = aap_integration.get("id") if aap_integration else None
    expected_credential_id = aap_integration.get("credential_id") if aap_integration else None
    checks = []
    for workflow in inventory.ao_workflows:
        nodes = workflow.get("aap_job_template_nodes", [])
        valid = all(
            (
                node.get("job_template_id") in template_ids
                or bool(node.get("job_template_name"))
            )
            and node.get("integration_id") == expected_integration_id
            and node.get("credential_id") == expected_credential_id
            for node in nodes
        )
        labels = workflow.get("labels", {})
        if isinstance(labels, dict) and str(labels.get("acceptance", "")).casefold() == "true":
            expected_template = {
                "AAP-Demo Acceptance | AO AAP Read-Only": "AAP-Demo Acceptance | AO Read-Only Diagnostic",
                "AAP-Demo Acceptance | Product Demos Read-Only": "AAP-Demo Acceptance | Product Demos Read-Only Diagnostic",
            }.get(workflow.get("name"))
            valid = bool(
                valid
                and expected_template
                and len(nodes) == 1
                and nodes[0].get("job_template_name") == expected_template
                and nodes[0].get("job_template_id") in template_ids
            )
        resource_id = workflow.get("id")
        checks.append(_result(
            f"wiring.workflow.{resource_id}",
            "ao_workflow",
            valid,
            "workflow AAP nodes use the effective addon integration and credential" if valid else "workflow has missing or incorrect AAP template, integration, or effective credential bindings",
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
