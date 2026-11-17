import pytest

from aap_demo.cluster import coredns
from aap_demo.core.errors import AapDemoError
from aap_demo.exec.runner import FakeRunner


def test_failed_resolver_read_does_not_write_vm_config(app_ctx, monkeypatch, tmp_path):
    key = tmp_path / "key"
    key.write_text("key")
    monkeypatch.setattr(coredns.ssh_mod, "detect_ssh_key", lambda _: key)
    runner = FakeRunner().fail("ssh")
    app_ctx.runner = runner
    with pytest.raises(AapDemoError, match="resolv.conf"):
        coredns.ensure_search_domain(app_ctx)
    assert len(runner.calls) == 1
