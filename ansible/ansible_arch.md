# Ansible Architecture for Large-Scale Microservices

A practical reference architecture for managing configuration and
deployments across **50--200 services** running on a mix of virtual
machines, containers, and Kubernetes.

## 1. Executive summary

Use a **federated platform model**:

-   A central platform team owns reusable Ansible Collections, shared
    roles, policies, and deployment guardrails.
-   Service teams own their service code, release artifacts, service
    metadata, and service-specific operational requirements.
-   Environment configuration is managed separately from application
    code.
-   CI/CD pipelines validate changes and orchestrate approved
    deployments.
-   Ansible manages Linux/VM configuration and VM-based deployments;
    Kubernetes-native tools manage workloads inside Kubernetes.

**Core principle:** teams should declare *what a service needs* in a
validated manifest, rather than writing arbitrary deployment playbooks
for every service.

## 2. Target architecture

``` text
 Service repositories                Environment configuration
 (code, tests, artifact)              (inventory, vars, rollout policy)
          |                                      |
          v                                      v
     Build pipeline                         Change review
 (tests, image/package, digest)                   |
          |                                      |
          +------------------+-------------------+
                             v
                     CI/CD orchestrator
              (validate, approve, deploy, verify)
                             |
               +-------------+-------------+
               |                           |
               v                           v
       Ansible automation             Kubernetes GitOps
       (VMs and Linux hosts)           (Helm + Argo CD/Flux)
               |                           |
               v                           v
       Hosts / load balancer          Kubernetes workloads
               +-------------+-------------+
                             |
                   Health + observability
```

### Team responsibilities

  -----------------------------------------------------------------------
  Area                    Primary owner           Responsibilities
  ----------------------- ----------------------- -----------------------
  Shared automation       Platform team           Collections, roles,
                                                  defaults, testing,
                                                  compatibility

  Service code and        Service team            Code, tests, build,
  artifact                                        version, immutable
                                                  artifact

  Service manifest        Service team, with      Runtime, ports, health
                          schema owned by         checks, config
                          platform                references, rollout
                                                  preferences

  Environment config      Platform / operations   Inventory, environment
                          with service input      overrides, policy

  Secrets                 Security/platform       Secret storage, access
                                                  policy, rotation

  Release orchestration   CI/CD/platform          Validation, approvals,
                                                  rollout, verification,
                                                  rollback

  Kubernetes desired      Platform + service team Helm charts or
  state                                           deployment definitions
                                                  and GitOps workflow
  -----------------------------------------------------------------------

## 3. Repository boundaries

A reasonable starting layout:

``` text
platform-ansible/
  collections/
  roles/
  playbooks/
  schemas/
  tests/
  ansible.cfg
  requirements.yml

service-orders/
  app/
  tests/
  service.yaml
  Dockerfile
  README.md

environment-config/
  inventories/
    dev/
    staging/
    production/
  group_vars/
  host_vars/
  policies/
  deployment-overrides/

platform-policies/
  schemas/
  policy-tests/
  approval-rules/
```

Keep `platform-policies` separate if governance needs independent
ownership or review. For a smaller organization, schemas and policies
can start inside `platform-ansible` and be split later.

### Repository rules

-   Pin dependencies and collection versions.
-   Require review for shared roles and production environment changes.
-   Avoid copying platform roles into each service repository.
-   Keep secrets out of Git; commit secret references, not secret
    values.
-   Keep application artifacts immutable and identify them by version
    plus digest.

## 4. Ansible Collections and roles

Use namespaced Collections so the platform API is explicit:

``` text
acme.linux_platform
  roles/
    baseline/
    hardening/
    users/
    monitoring_agent/
    log_agent/

acme.app_platform
  roles/
    runtime/
    service_config/
    release_deploy/
    service_manager/
    health_check/
    rollback/
```

An optional `acme.cloud_platform` Collection can contain cloud-specific
integrations. Prefer a small, stable public interface over many
overlapping roles.

### Role design guidance

-   Make roles idempotent.
-   Document inputs, defaults, outputs, and supported operating systems.
-   Use handlers for service reload/restart only when appropriate.
-   Separate configuration rendering from release deployment.
-   Avoid embedding environment-specific values in role code.
-   Test supported combinations and version compatibility.
-   Use tags carefully; do not make correctness depend on a fragile
    sequence of tags.

## 5. Service manifest

Define a versioned YAML schema that describes each service. Example:

``` yaml
apiVersion: platform.example.com/v1
kind: Service
metadata:
  name: orders-api
  team: commerce

runtime:
  type: python
  version: "3.12"

artifact:
  package: registry.example.com/orders-api
  version: "2026.10.20"
  digest: "sha256:REPLACE_WITH_REAL_DIGEST"

deployment:
  target: vm
  strategy: rolling
  maxUnavailable: 1
  drainBeforeDeploy: true

network:
  port: 8080

health:
  readinessPath: /ready
  livenessPath: /health
  timeoutSeconds: 3

config:
  LOG_LEVEL: INFO
  FEATURE_FLAG_X: "false"

secrets:
  - name: DATABASE_URL
    secretRef: secret-manager://production/orders/database-url

resources:
  cpu: "1"
  memory: "512Mi"
```

This is an illustrative template, not a complete schema. Replace the
sample artifact digest and adapt fields to your platform.

### Manifest design rules

-   Validate manifests against JSON Schema or an equivalent schema
    before deployment.
-   Reject unknown or unsupported fields where practical.
-   Keep non-secret configuration separate from secret values.
-   Use explicit artifact versions and digests; avoid mutable tags such
    as `latest`.
-   Define a versioning and migration policy for the manifest schema.
-   Add ownership, dependencies, deployment target, resource limits, and
    rollback metadata as needed.
-   Treat the manifest as input data, never as executable Ansible
    content.

## 6. Inventory and variable hierarchy

Use inventory to describe hosts and groups, and service manifests to
describe applications. Keep the responsibilities distinct.

A typical precedence strategy:

1.  Role defaults for safe generic defaults.
2.  Group variables for environment-wide settings.
3.  Service manifest for service-level declared settings.
4.  Explicit deployment overrides for approved exceptional cases.
5.  Secret manager references for credentials and other secret values.

Be deliberate about Ansible variable precedence; document which source
is authoritative for each field. Avoid maintaining the same setting in
multiple places.

## 7. Secrets and credentials

-   Prefer a dedicated secret manager and short-lived identity where
    available.
-   Store references to secrets in service metadata, not secret values.
-   If Ansible Vault is used, tightly control access to vault passwords
    and encrypted files.
-   Mark sensitive tasks with `no_log: true` where appropriate.
-   Prevent secrets from appearing in logs, command output, artifacts,
    and CI job summaries.
-   Define rotation, revocation, and incident-response procedures.
-   Use least-privilege credentials for each environment and deployment
    pipeline.

## 8. CI/CD workflow

### Application release pipeline

1.  Run unit, integration, security, and policy tests.
2.  Build a package or container image.
3.  Publish the immutable artifact.
4.  Record its version and digest.
5.  Update the service manifest or release reference.
6.  Open a reviewed change for the target environment.

### Automation / deployment pipeline

1.  Validate manifest schema and policy.
2.  Lint Ansible and check dependency versions.
3.  Run unit and role tests.
4.  Run integration tests in a disposable environment.
5.  Produce a deployment plan or preview where feasible.
6.  Require approval for production if policy demands it.
7.  Deploy in batches or canary stages.
8.  Check health, error rate, latency, and key business signals.
9.  Continue only when checks pass; otherwise stop and roll back or roll
    forward.
10. Record artifact digest, change request, approver, outcome, and
    deployed version.

## 9. Zero-downtime deployment on VMs

A typical rolling deployment:

1.  Select a small host batch.
2.  Remove a host from load-balancer traffic or drain connections.
3.  Install the immutable release in a new versioned directory.
4.  Render validated configuration.
5.  Run pre-start checks.
6.  Switch the active release and gracefully reload/restart the service
    if needed.
7.  Verify readiness and application-level health.
8.  Return the host to service.
9.  Continue to the next batch only after the checks pass.

Important caveats:

-   A rolling strategy alone does not guarantee zero downtime. The
    application, load balancer, health checks, and shutdown behavior
    must support it.
-   Configuration changes can be applied without restart only if the
    application supports runtime reload.
-   Database changes should use backward-compatible expand/contract
    migrations.
-   Define rollback conditions and ensure the previous
    artifact/configuration remains available.
-   Test failure cases, not just the happy path.

## 10. Testing strategy

  -----------------------------------------------------------------------
  Layer                               What to test
  ----------------------------------- -----------------------------------
  Manifest/schema                     Required fields, valid types,
                                      unsupported fields, policy
                                      violations

  Lint                                YAML, Ansible syntax, style, risky
                                      patterns

  Role unit tests                     Defaults, templates, idempotence,
                                      handler behavior

  Integration                         Supported OS/runtime versions and
                                      real service-manager behavior

  Deployment                          Drain, rollout, readiness, traffic
                                      restoration, rollback

  Resilience                          Host failure, health-check failure,
                                      artifact fetch failure, partial
                                      rollout

  Security                            Secret leakage, permissions,
                                      privilege boundaries, dependency
                                      scanning
  -----------------------------------------------------------------------

Use Molecule or an equivalent test harness for Ansible role testing
where appropriate.

## 11. Governance and operational guardrails

-   Publish a supported role and collection version matrix.
-   Use semantic versioning and a deprecation policy for shared
    automation interfaces.
-   Require code owners for platform-critical files.
-   Limit production credentials to approved pipelines and operators.
-   Enforce concurrency controls so two deployments cannot conflict on
    the same service/environment.
-   Define deployment windows and emergency procedures where necessary.
-   Keep an audit trail of who deployed what, where, and when.
-   Monitor deployment health and automatically stop on failed checks.
-   Review exceptions regularly; avoid permanent undocumented bypasses.

## 12. Tool boundaries

  -----------------------------------------------------------------------
  Need                                Preferred tool / approach
  ----------------------------------- -----------------------------------
  Provision VMs, networks, managed    Terraform or OpenTofu
  services                            

  Configure Linux hosts and VM-based  Ansible
  apps                                

  Build/test application artifacts    CI build system

  Deploy Kubernetes workloads         Helm plus Kubernetes controllers /
                                      GitOps such as Argo CD or Flux

  Manage secrets                      Dedicated secret manager; Ansible
                                      Vault where appropriate

  Observe services                    Metrics, logs, traces, alerting,
                                      and deployment markers
  -----------------------------------------------------------------------

Avoid using Ansible as a replacement for Kubernetes controllers for
normal in-cluster desired-state management. Avoid using Terraform as a
per-release application deployment engine.

## 13. Suggested implementation roadmap

### Phase 1 --- Foundations

-   Agree on service manifest schema and ownership.
-   Create the first shared Collection and a small set of roles.
-   Establish repository and review rules.
-   Add linting, schema validation, and secret-scanning.

### Phase 2 --- Pilot

-   Choose one low-risk service on a representative VM environment.
-   Implement deployment, health checks, and rollback.
-   Test idempotence and failure scenarios.
-   Document the service-team onboarding path.

### Phase 3 --- Standardize

-   Add supported runtime roles and service-manager integrations.
-   Publish versioned Collections.
-   Add environment policy and approval gates.
-   Add audit records and deployment health dashboards.

### Phase 4 --- Scale

-   Onboard services in waves.
-   Track exceptions and remove one-off patterns.
-   Add automated canary analysis and safe concurrency controls.
-   Keep Kubernetes and VM deployment paths distinct where their
    operational models differ.

## 14. Practical checklist

-   [ ] Shared roles live in versioned Ansible Collections.
-   [ ] Service manifests are schema-validated.
-   [ ] Artifacts are immutable and identified by digest.
-   [ ] Secrets are referenced, not committed as plaintext.
-   [ ] Environment configuration is reviewed separately.
-   [ ] Production deployment requires the right approvals.
-   [ ] Rollout pauses when health checks fail.
-   [ ] Rollback or roll-forward is tested.
-   [ ] Deployment actions are auditable.
-   [ ] Kubernetes workloads use Kubernetes-native desired-state
    management.
-   [ ] Ownership and support expectations are documented.

## 15. Official references

-   Ansible documentation: https://docs.ansible.com/
-   Ansible Collections:
    https://docs.ansible.com/ansible/latest/collections_guide/
-   Ansible best practices:
    https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html
-   Molecule documentation:
    https://ansible.readthedocs.io/projects/molecule/
-   Terraform documentation:
    https://developer.hashicorp.com/terraform/docs
-   OpenTofu documentation: https://opentofu.org/docs/
-   Helm documentation: https://helm.sh/docs/
-   Argo CD documentation: https://argo-cd.readthedocs.io/
-   Flux documentation: https://fluxcd.io/flux/
-   JSON Schema: https://json-schema.org/

------------------------------------------------------------------------

**Status:** Reference architecture and starting template. Adapt schema,
policies, roles, deployment logic, and examples to your infrastructure
before production use.
