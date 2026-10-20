"""Managed AAP-Demo resource inventory for live acceptance checks."""

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

try:
    from .redaction import redact
except ImportError:  # Direct execution via run.sh or python runner.py.
    from redaction import redact

if TYPE_CHECKING:
    from .clients.aap import AapClient
    from .clients.ao import AoClient


@dataclass
class ManagedResourceInventory:
    """Normalized resources created and maintained by AAP-Demo addons."""

    organizations: list[dict] = field(default_factory=list)
    projects: list[dict] = field(default_factory=list)
    inventories: list[dict] = field(default_factory=list)
    credentials: list[dict] = field(default_factory=list)
    job_templates: list[dict] = field(default_factory=list)
    execution_environments: list[dict] = field(default_factory=list)
    ao_credentials: list[dict] = field(default_factory=list)
    ao_integrations: list[dict] = field(default_factory=list)
    ao_workflows: list[dict] = field(default_factory=list)


_AAP_ENDPOINTS = {
    "organizations": "/api/v2/organizations/",
    "projects": "/api/v2/projects/",
    "inventories": "/api/v2/inventories/",
    "credentials": "/api/v2/credentials/",
    "job_templates": "/api/v2/job_templates/",
    "execution_environments": "/api/v2/execution_environments/",
}
_AO_ENDPOINTS = {
    "ao_credentials": "/api/v1/credentials",
    "ao_integrations": "/api/v1/integrations",
    "ao_workflows": "/api/v1/workflows",
}


def _id(value: object) -> object | None:
    if isinstance(value, dict):
        return value.get("id")
    return value


def _index(items: list[dict]) -> dict[object, dict]:
    return {item["id"]: item for item in items if item.get("id") is not None}


def _resolved_id(index: dict[object, dict], value: object) -> object | None:
    """Return the target's canonical ID when an API serializes it as text."""
    raw_id = _id(value)
    if raw_id in index:
        return index[raw_id].get("id")
    for candidate, item in index.items():
        if str(candidate) == str(raw_id):
            return item.get("id")
    return raw_id


def _contains_id(values: set[object], value: object) -> bool:
    return any(str(candidate) == str(_id(value)) for candidate in values)


def _marker(managed_markers: dict[str, str], resource_type: str) -> str:
    return str(managed_markers.get(resource_type, managed_markers.get(resource_type.removeprefix("ao_"), ""))).casefold()


def _stable_match(resource: dict, resource_type: str) -> bool:
    name = str(resource.get("name", "")).casefold()
    description = str(resource.get("description", "")).casefold()
    if resource_type == "organizations":
        return name in {"default", "ansible product demos (apd)"}
    if resource_type == "projects":
        return name in {"aap orchestrator demos", "aap demo control plane", "ansible product demos", "apd bootstrap project"}
    if resource_type == "inventories":
        return name == "ansible product demos inventory"
    if resource_type == "credentials":
        return name in {"aap credential", "openshift credential", "aap-demo aap token", "aap-demo mcp token"}
    if resource_type == "job_templates":
        return description.startswith("aap orchestrator demo") or name == "sync ao workflows from tmm" or name.startswith("apd |") or name.startswith("aap-demo acceptance |")
    if resource_type == "execution_environments":
        return name == "product demos ee"
    if resource_type == "ao_integrations":
        return name in {"aap-demo aap", "aap-demo mcp server"}
    if resource_type == "ao_credentials":
        return name in {"aap-demo aap token", "aap-demo mcp token"}
    if resource_type == "ao_workflows":
        labels = resource.get("labels", {})
        return isinstance(labels, dict) and str(labels.get("aap-demo", "")).casefold() == "true"
    return False


def _matches(resource: dict, marker: str, resource_type: str, *, workflow: bool = False) -> bool:
    values = [resource.get("name", ""), resource.get("description", "")]
    if workflow:
        labels = resource.get("labels", {})
        if isinstance(labels, dict):
            values.extend(f"{key}={value}" for key, value in labels.items())
    return _stable_match(resource, resource_type) or (bool(marker) and any(marker in str(value).casefold() for value in values))


def _safe(resource: dict) -> dict:
    """Copy an API record through the shared redactor before retaining it."""
    sanitized = redact(resource)
    return dict(sanitized) if isinstance(sanitized, dict) else {}


def _credential_type(resource: dict) -> str | None:
    credential_type = resource.get("credential_type")
    if isinstance(credential_type, dict):
        name = credential_type.get("name")
    else:
        name = resource.get("credential_type_name")
    summary = resource.get("summary_fields")
    if name is None and isinstance(summary, dict):
        credential_type = summary.get("credential_type")
        if isinstance(credential_type, dict):
            name = credential_type.get("name")
    return str(name) if name else None


def _workflow_nodes(workflow: dict, templates: dict[object, dict]) -> list[dict]:
    definition = workflow.get("workflow_definition", workflow)
    nodes = definition.get("nodes", []) if isinstance(definition, dict) else []
    normalized: list[dict] = []
    for node in nodes if isinstance(nodes, list) else []:
        if not isinstance(node, dict) or node.get("type") != "aap_job_template":
            continue
        parameters = node.get("parameters", node.get("config", {}))
        parameters = parameters if isinstance(parameters, dict) else {}
        template_id = _resolved_id(templates, parameters.get("job_template_id"))
        parameter_name = parameters.get("job_template_name")
        if template_id is None and isinstance(parameter_name, str):
            template_id = next(
                (
                    candidate_id for candidate_id, candidate in templates.items()
                    if candidate.get("name") == parameter_name
                ),
                None,
            )
        template = templates.get(template_id, {})
        normalized.append({
            "id": node.get("id", node.get("name")),
            "job_template_id": template_id,
            "job_template_name": template.get("name", parameter_name),
            "integration_id": _id(parameters.get("integration_id")),
            "credential_id": _id(parameters.get("credential_id")),
        })
    return normalized


def build_inventory(
    aap: "AapClient", ao: "AoClient", managed_markers: dict[str, str]
) -> ManagedResourceInventory:
    """Read only addon-managed resources and retain their resolved references."""
    aap_resources = {name: aap.list_all(path) for name, path in _AAP_ENDPOINTS.items()}
    ao_resources = {name: ao.list_all(path) for name, path in _AO_ENDPOINTS.items()}

    organizations = [_safe(item) for item in aap_resources["organizations"] if _matches(item, _marker(managed_markers, "organizations"), "organizations")]
    organization_ids = set(_index(organizations))
    projects = [_safe(item) for item in aap_resources["projects"] if _matches(item, _marker(managed_markers, "projects"), "projects")]
    projects_by_id = _index(projects)
    inventories = [_safe(item) for item in aap_resources["inventories"] if _matches(item, _marker(managed_markers, "inventories"), "inventories")]
    managed_templates = [
        item
        for item in aap_resources["job_templates"]
        if _matches(item, _marker(managed_markers, "job_templates"), "job_templates")
    ]
    template_credentials = {
        template_id: aap.list_all(f"/api/v2/job_templates/{template_id}/credentials/")
        for template in managed_templates
        if (template_id := _id(template.get("id"))) is not None
    }
    referenced_credential_ids = {
        _id(credential.get("id"))
        for credentials_for_template in template_credentials.values()
        for credential in credentials_for_template
        if isinstance(credential, dict) and _id(credential.get("id")) is not None
    }
    credentials = [
        _safe(item)
        for item in aap_resources["credentials"]
        if _matches(item, _marker(managed_markers, "credentials"), "credentials")
        or _contains_id(referenced_credential_ids, item.get("id"))
    ]
    referenced_execution_environment_ids = {
        _id(template.get("execution_environment"))
        for template in managed_templates
        if _id(template.get("execution_environment")) is not None
    }
    execution_environments = [
        _safe(item)
        for item in aap_resources["execution_environments"]
        if _matches(item, _marker(managed_markers, "execution_environments"), "execution_environments")
        or _contains_id(referenced_execution_environment_ids, item.get("id"))
    ]
    inventories_by_id = _index(inventories)
    credentials_by_id = _index(credentials)
    execution_environments_by_id = _index(execution_environments)

    normalized_projects = []
    for project in projects:
        record = dict(project)
        record["organization_id"] = _resolved_id(_index(organizations), project.get("organization"))
        record["managed_organization"] = record["organization_id"] in organization_ids
        normalized_projects.append(record)

    job_templates = []
    for raw_template in managed_templates:
        template = _safe(raw_template)
        template_id = template.get("id")
        credentials_for_template = template_credentials.get(template_id, [])
        project_id = _resolved_id(projects_by_id, template.get("project"))
        inventory_id = _resolved_id(inventories_by_id, template.get("inventory"))
        execution_environment_id = _resolved_id(execution_environments_by_id, template.get("execution_environment"))
        summary = template.get("summary_fields", {})
        capabilities = summary.get("user_capabilities", {}) if isinstance(summary, dict) else {}
        template.update({
            "organization_id": _resolved_id(_index(organizations), template.get("organization")),
            "project_id": project_id,
            "project_name": projects_by_id.get(project_id, {}).get("name"),
            "inventory_id": inventory_id,
            "inventory_name": inventories_by_id.get(inventory_id, {}).get("name"),
            "execution_environment_id": execution_environment_id,
            "execution_environment_name": execution_environments_by_id.get(execution_environment_id, {}).get("name"),
            "credential_ids": [_resolved_id(credentials_by_id, credential.get("id")) for credential in credentials_for_template if isinstance(credential, dict) and _id(credential.get("id")) is not None],
            "can_start": capabilities.get("start", template.get("can_start")),
        })
        job_templates.append(template)
    templates_by_id = _index(job_templates)

    normalized_credentials = []
    for credential in credentials:
        record = dict(credential)
        record["organization_id"] = _resolved_id(_index(organizations), credential.get("organization"))
        record["credential_type_name"] = _credential_type(credential)
        normalized_credentials.append(record)

    ao_credentials = [
        _safe(item)
        for item in ao_resources["ao_credentials"]
        if _matches(
            item,
            _marker(managed_markers, "ao_credentials"),
            "ao_credentials",
        )
    ]

    ao_integrations = []
    for raw_integration in ao_resources["ao_integrations"]:
        if not _matches(raw_integration, _marker(managed_markers, "ao_integrations"), "ao_integrations"):
            continue
        integration = _safe(raw_integration)
        configuration = integration.get("configuration", {})
        configuration = configuration if isinstance(configuration, dict) else {}
        integration["endpoint"] = integration.get("base_url") or configuration.get("base_url") or configuration.get("url")
        integration["integration_type"] = integration.get("integration_type") or configuration.get("integration_type")
        integration["credential_id"] = _id(integration.get("management_credential_id", integration.get("credential_id")))
        ao_integrations.append(integration)

    ao_workflows = []
    for raw_workflow in ao_resources["ao_workflows"]:
        if not _matches(raw_workflow, _marker(managed_markers, "ao_workflows"), "ao_workflows", workflow=True):
            continue
        workflow = _safe(raw_workflow)
        workflow["aap_job_template_nodes"] = _workflow_nodes(workflow, templates_by_id)
        ao_workflows.append(workflow)

    return ManagedResourceInventory(
        organizations=organizations,
        projects=normalized_projects,
        inventories=inventories,
        credentials=normalized_credentials,
        job_templates=job_templates,
        execution_environments=execution_environments,
        ao_credentials=ao_credentials,
        ao_integrations=ao_integrations,
        ao_workflows=ao_workflows,
    )
