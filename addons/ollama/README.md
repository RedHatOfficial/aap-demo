# Ollama (removed)

Earlier releases ran Ollama in the cluster for AO. AO now uses Ollama running on
your machine ([ADR-046](../../docs/adr/046-ao-host-ollama.md)), so this addon only
removes the old install:

```bash
aap-demo disable ollama
```

That deletes the `aap-demo-ollama` namespace and the `aap-demo-ollama-anyuid`
ClusterRoleBinding. `aap-demo enable ollama` stops and explains how to set up
Ollama on the host.

To use Ollama with AO, install it from <https://ollama.com/download>, start it,
pull a model that supports tools (`ollama pull <model>`), and run
`aap-demo enable ao`. See the AO section of [the addons guide](../../docs/guides/addons.md).
