# Help text

function Show-AapDemoWelcome {
    @'
aap-demo - Deploy AAP 2.7 to OpenShift Local (Windows PowerShell)

Usage: aap-demo [options] <command>

Commands:
  deploy          Deploy AAP 2.7
  deploy-operator Deploy operator only
  status          Show cluster and AAP status
  diagnose        Quick health check (partial on Windows)
  create          Create OpenShift Local cluster
  destroy         Delete cluster
  stop            Stop cluster
  start           Start cluster
  help            Show full help

Examples:
  aap-demo create
  aap-demo deploy
  aap-demo status

Run 'aap-demo help' for documentation.
'@ | Write-Host
}

function Show-AapDemoHelp {
    @'
aap-demo - Deploy AAP 2.7 to OpenShift Local (Windows)

USAGE:
  aap-demo [command] [options]

COMMANDS:
  create              Create CRC cluster (MicroShift recommended)
  deploy              Deploy AAP 2.7 operator and instance
  deploy-operator     Deploy operator only
  status              Cluster status, routes, credentials
  diagnose            Environment health check
  start / stop        Start or stop CRC VM
  destroy             Delete entire cluster
  help                This help

ENVIRONMENT:
  NAMESPACE           Target namespace (default: aap-operator)
  QUIET               Suppress prompts (true/false)
  FORCE               Force redeploy if AAP exists (true/false)
  CRC_CPUS            VM CPUs (default: 8)
  CRC_MEMORY          VM memory MiB (default: 16384)
  CRC_DISK            VM disk GiB (default: 100)
  CRC_PV_SIZE         PV reservation GiB (default: 50)

INSTALL:
  .\powershell\Install.ps1

DOCS:
  docs/windows/ARCHITECTURE.md   Architecture and phased plan
  docs/windows/QUICK-START.md    Windows quick start

macOS/Linux users: use ./install.sh and aap-demo.sh at repo root.
'@ | Write-Host
}

function Enter-AapDemoSsh {
    $key = Get-AapDemoCrcSshKey
    $args = @(Get-AapDemoCrcSshArgs) + @('core@127.0.0.1')
    & ssh @args
}
