"""``--ocp-version`` resolution and the per-major profiles (ADR-041)."""

from __future__ import annotations

import io
import re
import urllib.error
from types import SimpleNamespace

import pytest

from aap_demo.cli.main import build_parser
from aap_demo.core import schema
from aap_demo.core.errors import AapDemoError
from aap_demo.infra import bundle_mirror, ocp_list
from aap_demo.infra import crc as infra_crc
from aap_demo.infra import ocp_version as ocp

MIRROR = ["4.21.0", "4.21.7", "4.22.0", "4.22.13", "5.0.0"]


def _no_network():
    raise AssertionError("the mirror must not be read for this value")


def test_profiles_load_for_4_and_5() -> None:
    profiles = ocp.load_profiles()
    assert sorted(profiles) == [4, 5]
    assert profiles[4].crc_bundle == profiles[4].stable
    assert profiles[5].crc_bundle is None
    assert "stable-2.6" not in profiles[5].aap_channels
    assert profiles[5].operators == ()


def test_the_4_profile_matches_the_pinned_crc_release() -> None:
    """crc-release and the 4 profile move together when CRC is bumped."""
    assert infra_crc.managed_crc_release() == "2.64.0"
    assert ocp.load_profiles()[4].crc_bundle == "4.22.13"


def test_unset_is_the_newest_supported_stable_without_the_network() -> None:
    resolved = ocp.resolve("", available=_no_network)
    assert resolved.version == "4.22.13"
    assert resolved.builtin and resolved.stable


def test_unset_follows_a_newly_supported_major() -> None:
    profiles = ocp.load_profiles()
    profiles[5] = ocp.Profile(**{**profiles[5].__dict__, "supported": True})
    assert ocp.resolve("", profiles=profiles, available=_no_network).version == "5.0.0"


@pytest.mark.parametrize("value", ["4", "4.22", "4.22.13"])
def test_major_minor_and_exact_stable_agree(value: str) -> None:
    resolved = ocp.resolve(value, available=_no_network)
    assert (resolved.version, resolved.builtin) == ("4.22.13", True)


@pytest.mark.parametrize("value", ["5", "5.0", "5.0.0"])
def test_5_needs_a_download_but_no_lookup(value: str) -> None:
    resolved = ocp.resolve(value, available=_no_network)
    assert resolved.version == "5.0.0"
    assert resolved.builtin is False and resolved.stable is True


def test_an_older_minor_takes_its_newest_patch_from_the_mirror() -> None:
    resolved = ocp.resolve("4.21", available=lambda: MIRROR)
    assert resolved.version == "4.21.7"
    assert resolved.stable is False and resolved.builtin is False


def test_an_exact_version_must_be_on_the_mirror() -> None:
    assert ocp.resolve("4.22.0", available=lambda: MIRROR).version == "4.22.0"
    with pytest.raises(AapDemoError, match="No MicroShift 4.22.22 bundle"):
        ocp.resolve("4.22.22", available=lambda: MIRROR)


@pytest.mark.parametrize(
    ("value", "message"),
    [
        ("3", "OpenShift 3 is not supported"),
        ("6.0", "OpenShift 6 is not supported"),
        ("4.20", "older than 4.21"),
        ("4.12.9", "older than 4.21"),
        ("latest", "Not an OpenShift version"),
        ("4.22.13.1", "Not an OpenShift version"),
    ],
)
def test_bad_values_are_refused_before_any_lookup(value: str, message: str) -> None:
    with pytest.raises(AapDemoError, match=re.escape(message)):
        ocp.resolve(value, available=_no_network)


@pytest.mark.parametrize(
    ("requested", "cluster", "expected"),
    [
        ("", "5.0.0", True),
        ("4", "4.22.13", True),
        ("4", "5.0.0", False),
        ("4.22", "4.22.13", True),
        ("4.22", "4.21.7", False),
        ("4.22.13", "4.22.13", True),
        ("4.22.0", "4.22.13", False),
    ],
)
def test_matches(requested: str, cluster: str, expected: bool) -> None:
    assert ocp.matches(requested, cluster) is expected


def _ctx(config: dict, env: dict):
    return SimpleNamespace(config=SimpleNamespace(get=lambda k, d=None: config.get(k, d)), env=env)


def test_requested_reads_only_the_new_setting() -> None:
    ctx = _ctx({"crc.ocp_version": " 5 ", "crc.version": "4.21"}, {"CRC_VERSION": "4.21"})
    assert ocp.requested(ctx) == "5"
    assert ocp.requested(_ctx({"crc.version": "4.21"}, {"CRC_VERSION": "4.21"})) == ""


def test_the_old_floor_is_named_for_a_deprecation_note() -> None:
    assert ocp.legacy_setting(_ctx({}, {"CRC_VERSION": "4.21"})) == "CRC_VERSION"
    assert ocp.legacy_setting(_ctx({"crc.version": "4.21"}, {})) == "crc.version"
    assert ocp.legacy_setting(_ctx({}, {})) is None


@pytest.mark.parametrize(
    ("value", "cluster", "channel", "message"),
    [
        ("5", "4.22.13", "stable-2.7", "runs OpenShift 4.22.13, not 5"),
        ("", "5.0.0", "stable-2.6", "stable-2.6 is not available on OpenShift 5"),
        ("4", "5.0.0", "stable-2.7", "runs OpenShift 5.0.0, not 4"),
    ],
)
def test_check_cluster_refuses(value: str, cluster: str, channel: str, message: str) -> None:
    with pytest.raises(AapDemoError, match=re.escape(message)):
        ocp.check_cluster(value, cluster, channel=channel)


@pytest.mark.parametrize(
    ("value", "cluster", "channel"),
    [("", "4.22.13", "stable-2.6"), ("5", "5.0.0", "stable-2.7"), ("4.21", "4.21.7", "stable-2.7")],
)
def test_check_cluster_allows(value: str, cluster: str, channel: str) -> None:
    ocp.check_cluster(value, cluster, channel=channel)


def test_versions_in_keeps_full_versions_only() -> None:
    names = ["../", "4.22.13/", "latest/", "4.9.0/", "4.22.0/", "5.0.0", "4.22/"]
    assert ocp.versions_in(names) == ["4.9.0", "4.22.0", "4.22.13", "5.0.0"]


def test_schema_declares_the_flag_and_env() -> None:
    prop = schema.section("crc")["properties"]["ocp_version"]
    assert prop["x-cli"] == {"flag": "--ocp-version"}
    assert prop["x-env"] == "CRC_OCP_VERSION"


# --- the mirror listing and ocp-version-list -------------------------------


GATEWAY = "https://developers.redhat.com/content-gateway/file/pub/cgw/crc/bundles/microshift"


def _listing(*hrefs: str) -> bytes:
    links = "".join(f'<a href="{h}">x</a><a href="#file">y</a>' for h in hrefs)
    return f"<html><body>{links}</body></html>".encode()


def _mirror(pages: dict):
    def opener(url: str, timeout: int):
        return io.BytesIO(pages[url])

    return opener


def _pages() -> dict:
    top = f"{bundle_mirror.BASE_URL}/"
    pages = {
        top: _listing(
            *(
                f"https://mirror.openshift.com/pub/cgw/crc/bundles/microshift/{v}/"
                for v in ["4.12.9", "4.21.7", "4.22.13", "5.0.0"]
            )
        )
    }
    for version, arches in {"4.21.7": ["arm64"], "4.22.13": ["arm64"], "5.0.0": ["amd64"]}.items():
        pages[bundle_mirror.version_url(version)] = _listing(
            f"{GATEWAY}/{version}/sha256sum.txt.sig",
            *(f"{GATEWAY}/{version}/crc_microshift_vfkit_{version}_{a}.crcbundle" for a in arches),
        )
    return pages


def test_bundle_names_per_host() -> None:
    assert bundle_mirror.bundle_name("5.0.0", system="Darwin", machine="arm64") == (
        "crc_microshift_vfkit_5.0.0_arm64.crcbundle"
    )
    assert bundle_mirror.bundle_name("5.0.0", system="Linux", machine="x86_64") == (
        "crc_microshift_libvirt_5.0.0_amd64.crcbundle"
    )
    with pytest.raises(Exception, match="No MicroShift bundle"):
        bundle_mirror.bundle_name("5.0.0", system="Windows", machine="arm64")


def test_host_versions_reads_only_versions_at_or_above_the_minimum() -> None:
    opener = _mirror(_pages())
    found = bundle_mirror.host_versions(
        minimum="4.21", system="Darwin", machine="arm64", opener=opener
    )
    # 4.12.9 is never fetched (it has no page in the fake), 5.0.0 has no arm64 bundle.
    assert found == ["4.21.7", "4.22.13"]


def test_rows_mark_stable_default_and_source() -> None:
    table = ocp_list.rows(
        crc_release="2.64.0", host_versions=lambda m: ["4.21.7", "4.22.13", "5.0.0"]
    )
    by_version = {row["version"]: row for row in table}
    assert [row["version"] for row in table] == ["5.0.0", "4.22.13", "4.21.7"]
    assert by_version["4.22.13"]["status"] == "stable, default"
    assert by_version["4.22.13"]["source"] == "CRC 2.64.0 (built in)"
    assert by_version["4.22.13"]["default"] is True
    assert by_version["5.0.0"]["status"] == "stable, not default yet"
    assert by_version["5.0.0"]["source"] == "download"
    assert by_version["4.21.7"]["status"] == "untested"


def test_rows_say_when_this_host_has_no_bundle() -> None:
    table = ocp_list.rows(crc_release="2.64.0", host_versions=lambda m: ["4.22.13"])
    five = next(row for row in table if row["version"] == "5.0.0")
    assert five["source"] == "no bundle for this host"


def test_rows_work_offline_with_the_pinned_versions() -> None:
    def offline(minimum: str):
        raise urllib.error.URLError("no network")

    table = ocp_list.rows(crc_release="2.64.0", host_versions=offline)
    assert [row["version"] for row in table] == ["5.0.0", "4.22.13"]
    assert all(row["checked"] is False for row in table)
    assert "(not checked)" in ocp_list.render_text(table)


def test_all_lists_versions_below_the_minimum() -> None:
    seen: list = []

    def listing(minimum: str):
        seen.append(minimum)
        return ["4.12.9", "4.22.13"]

    table = ocp_list.rows(crc_release="2.64.0", show_all=True, host_versions=listing)
    assert seen == ["0.0.0"]
    assert next(r for r in table if r["version"] == "4.12.9")["status"] == "not supported"


def test_ocp_version_list_is_in_help() -> None:
    assert "ocp-version-list" in build_parser().format_help()


def test_aap_ocp_version_with_another_major_is_refused() -> None:
    with pytest.raises(AapDemoError, match="AAP_OCP_VERSION=4.22 does not match"):
        ocp.check_cluster("", "5.0.0", channel="stable-2.7", index="4.22")
    ocp.check_cluster("", "5.0.0", channel="stable-2.7", index="5.0")
    ocp.check_cluster("", "4.22.13", channel="stable-2.7", index="")
