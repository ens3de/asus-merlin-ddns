"""Offline integration tests; never source production settings or use real APIs.

Run: python3 -m unittest discover -s ddns/tests -v
Override DDNS_TEST_SHELL to repeat with another POSIX-compatible shell.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
SHELL = os.environ.get("DDNS_TEST_SHELL", "/bin/sh")
FAKE_TOKEN = "TEST_TOKEN_NEVER_LOG_THIS"


def record(name="wg.example.com", record_id="wg6", family="AAAA", source=None):
    return {
        "schema_version": 1, "enabled": True, "provider": "cloudflare", "name": name,
        family: {"id": record_id, "source": source or {
            "type": "prefix_iid", "interface": "br0", "iid": "0011:32ff:fe29:0a81"}},
    }


class DDNS(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ddns-test-")
        self.root = Path(self.tmp.name)
        self.confdir = self.root / "conf.d"
        self.confdir.mkdir()
        self.bindir = self.root / "bin"
        self.bindir.mkdir()
        for name in ["ip", "curl", "logger"]:
            target = self.bindir / name
            shutil.copyfile(PROJECT / "tests/mock-command.py", target)
            target.chmod(0o700)
        self.settings = self.root / "settings.conf"
        self.settings.write_text(
            f"CF_API_TOKEN='{FAKE_TOKEN}'\nCF_ZONE_ID='testzone'\n"
            f"CONF_DIR='{self.confdir}'\nSTATE_FILE='{self.root / 'state.json'}'\n"
            "LOG_LEVEL=info\nNO_CHANGE_WINDOW_SECONDS=43200\n"
        )
        self.env = dict(os.environ, DDNS_TEST_ROOT=str(self.root),
                        PATH=str(self.bindir) + os.pathsep + os.environ["PATH"])
        # Prevent developer environment settings from leaking into fixtures.
        for name in ["CONF_DIR", "STATE_FILE", "LOG_FILE", "BARK_KEY", "CONFIG_FILE", "REFRESH_INTERVAL_SECONDS"]:
            self.env.pop(name, None)
        self.interfaces = {
            "-6:br0": "2: br0 inet6 2408:8207:6c24:a40::1/64 scope global dynamic mngtmpaddr preferred_lft 600sec",
            "-6:ppp0": "3: ppp0 inet6 2408:8206:1::99/64 scope global preferred_lft forever",
            "-4:ppp0": "3: ppp0 inet 203.0.113.9/32 scope global ppp0",
        }
        self.api = {
            "wg6": {"id": "wg6", "name": "wg.example.com", "type": "AAAA", "content": "2001:db8::1", "proxied": False},
            "r4": {"id": "r4", "name": "router.example.com", "type": "A", "content": "203.0.113.1", "proxied": False},
            "r6": {"id": "r6", "name": "router.example.com", "type": "AAAA", "content": "2001:db8::1", "proxied": False},
            "txt1": {"id": "txt1", "name": "hidden.example.com", "type": "TXT", "content": "not-listed", "proxied": False},
        }
        self.http = {"https://lookup.invalid/v4": {"body": "198.51.100.22"},
                     "https://lookup.invalid/v6": {"body": '{"ip":"2606:4700::1111"}'}}
        self.zones = [{"id": "testzone", "name": "example.com", "status": "active"},
                      {"id": "otherzone", "name": "example.net", "status": "active"}]
        self.fixture_files()

    def tearDown(self):
        self.tmp.cleanup()

    def fixture_files(self):
        for filename, data in [("interfaces.json", self.interfaces), ("api.json", self.api),
                               ("http.json", self.http), ("zones.json", self.zones)]:
            (self.root / filename).write_text(json.dumps(data))

    def put(self, task=None, data=None):
        data = data or record()
        task = data["name"] if task is None else task
        (self.confdir / f"{task}.json").write_text(json.dumps(data))

    def run_script(self, *args, manager=False, unified_manager=False, input=None, ok=True):
        script = PROJECT / "cloudflare-ddns"
        prefix = ["--config", str(self.settings)]
        if manager or unified_manager:
            prefix = ["config", "--config", str(self.settings)]
        result = subprocess.run([SHELL, str(script), *prefix, *args],
                                env=self.env, input=input, capture_output=True, text=True,
                                errors="replace", timeout=30)
        self.assertNotIn(FAKE_TOKEN, result.stdout + result.stderr)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def calls(self):
        path = self.root / "calls.jsonl"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        self.assertNotIn(FAKE_TOKEN, json.dumps(calls))
        return calls

    def run_init(self, config, input, ok=True):
        result = subprocess.run(
            [SHELL, str(PROJECT / "cloudflare-ddns"), "init", "--config", str(config)],
            env=self.env, input=input, capture_output=True, text=True, errors="replace", timeout=30)
        self.assertNotIn(FAKE_TOKEN, result.stdout + result.stderr)
        self.assertNotIn("NEW_TOKEN_NEVER_PRINT", result.stdout + result.stderr)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def test_init_selects_zone_and_atomically_writes_private_config(self):
        config = self.root / "new.conf"
        new_confdir = self.root / "records"
        state = self.root / "new-state.json"
        answers = ("NEW_TOKEN_NEVER_PRINT\n2\n" + str(new_confdir) + "\n" + str(state) +
                   "\n\nddns-test\n-\n3600\n4\n9\nn\nyes\n")
        result = self.run_init(config, answers)
        self.assertIn("example.net", result.stderr)
        self.assertNotIn("otherzone", result.stderr)
        self.assertIn("确认写入以上配置? 输入 yes 确认:", result.stderr)
        self.assertTrue(new_confdir.is_dir())
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        content = config.read_text()
        self.assertIn("CF_ZONE_ID='otherzone'", content)
        self.assertIn("LOG_TAG='ddns-test'", content)
        self.assertIn("REFRESH_INTERVAL_SECONDS='3600'", content)
        self.assertEqual(self.calls()[0]["url"],
                         "https://api.cloudflare.com/client/v4/zones?per_page=50&page=1")

    def test_init_preserves_existing_secret_and_cancel_preserves_file(self):
        before = self.settings.read_bytes()
        # Blank Token preserves it; all other blanks preserve defaults. Reject final commit.
        result = self.run_init(self.settings, "\n\n\n\n\n\n\n\n\n\n\nno\n", ok=False)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertNotIn("Zone ID", result.stderr)

    def test_init_rejects_invalid_token_before_network(self):
        config = self.root / "invalid.conf"
        self.run_init(config, "bad token\n", ok=False)
        self.assertFalse(config.exists())
        self.assertEqual(self.calls(), [])

    def test_validate_and_dry_run_have_no_dns_or_state_writes(self):
        self.put()
        self.run_script("--check")
        result = self.run_script("--dry-run", "--ipv6", "2001:db8::777")
        self.assertEqual(json.loads(result.stdout)["address"], "2408:8207:6c24:a40:11:32ff:fe29:a81")
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.root / "state.json").exists())

    def test_independent_sources_and_cache(self):
        self.put()
        router = record("router.example.com", "r4", "A", {"type": "interface", "interface": "ppp0"})
        router["AAAA"] = {"id": "r6", "source": {"type": "interface", "interface": "ppp0"}}
        self.put("router.example.com", router)
        self.run_script()
        changes = {c["url"].rsplit("/", 1)[-1]: json.loads(c["payload"])["content"] for c in self.calls() if c["method"] == "PATCH"}
        self.assertEqual(changes["r4"], "203.0.113.9")
        self.assertEqual(changes["r6"], "2408:8206:1:0:0:0:0:99")
        self.assertEqual(changes["wg6"], "2408:8207:6c24:a40:11:32ff:fe29:a81")
        count = len(self.calls())
        self.run_script()
        self.assertEqual(len(self.calls()), count)
        self.assertEqual(len(json.loads((self.root / "state.json").read_text())), 3)

    def test_prefix_change_only_updates_affected_record(self):
        self.put()
        self.put("router.example.com", record("router.example.com", "r4", "A", {"type": "interface", "interface": "ppp0"}))
        self.run_script()
        self.interfaces["-6:br0"] = self.interfaces["-6:br0"].replace(":a40:", ":b40:")
        self.fixture_files()
        self.run_script()
        patches = [c for c in self.calls() if c["method"] == "PATCH"]
        self.assertEqual(len(patches), 3)
        self.assertIn(":b40:", patches[-1]["payload"])

    def test_partial_failure_does_not_cache_failure_or_block_other_task(self):
        self.put()
        self.put("router.example.com", record("router.example.com", "r4", "A", {"type": "interface", "interface": "ppp0"}))
        self.api["r4"]["fail"] = True
        self.fixture_files()
        result = self.run_script(ok=False)
        self.assertNotIn("DO_NOT_LEAK_RESPONSE", result.stderr)
        self.assertEqual(len(json.loads((self.root / "state.json").read_text())), 1)
        self.api["r4"].pop("fail")
        self.fixture_files()
        self.run_script()
        self.assertEqual(len(json.loads((self.root / "state.json").read_text())), 2)

    def test_wrong_id_metadata_and_proxied_record_are_not_modified(self):
        self.put()
        self.api["wg6"]["name"] = "other.example.com"
        self.fixture_files()
        self.run_script(ok=False)
        self.assertFalse(any(c["method"] == "PATCH" for c in self.calls()))
        self.api["wg6"].update(name="wg.example.com", proxied=True)
        self.fixture_files()
        self.run_script(ok=False)
        self.assertFalse(any(c["method"] == "PATCH" for c in self.calls()))

    def test_no_source_fallback_on_missing_prefix(self):
        self.put()
        self.interfaces["-6:br0"] = ""
        self.fixture_files()
        self.run_script("--ipv6", "2001:db8::123", ok=False)
        self.assertEqual(self.calls(), [])

    def test_ambiguous_prefixes_rejected_but_old_deprecated_ignored(self):
        self.put()
        self.interfaces["-6:br0"] += "\n2: br0 inet6 2001:db8:2::1/64 scope global preferred_lft 100sec"
        self.fixture_files()
        self.run_script("--dry-run", ok=False)
        self.interfaces["-6:br0"] = self.interfaces["-6:br0"].replace("preferred_lft 100sec", "deprecated preferred_lft 0sec")
        self.fixture_files()
        self.run_script("--dry-run")

    def test_same_prefix_multiple_addresses_is_not_ambiguous(self):
        self.put()
        self.interfaces["-6:br0"] += "\n2: br0 inet6 2408:8207:6c24:a40::2/64 scope global preferred_lft 600sec"
        self.fixture_files()
        self.run_script("--dry-run")

    def test_filters_unusable_interface_addresses(self):
        self.put(data=record(source={"type": "interface", "interface": "br0"}))
        for flag in ["temporary", "tentative", "dadfailed", "deprecated"]:
            self.interfaces["-6:br0"] += f"\n2: br0 inet6 2001:db8::{len(flag)}/64 scope global {flag} preferred_lft 20sec"
        self.interfaces["-6:br0"] += "\n2: br0 inet6 fd00::1/64 scope global preferred_lft forever"
        self.fixture_files()
        self.run_script("--dry-run")

    def test_malformed_config_blocks_all_network_calls(self):
        self.put()
        (self.confdir / "BAD.json").write_text('{"enabled":true}')
        self.run_script(ok=False)
        self.assertEqual(self.calls(), [])

    def test_duplicate_records_rejected(self):
        self.put()
        self.put("other.example.com")
        self.run_script("--check", ok=False)

    def test_source_schema_rejects_wrong_family_and_commands(self):
        self.put(data=record(family="A"))
        self.run_script("--check", ok=False)
        r = record(source={"type": "http", "url": "https://lookup.invalid/v4", "parse_command": "touch /tmp/should-not-run"})
        self.put(data=r)
        self.run_script("--check", ok=False)

    def test_argument_sources_are_family_specific(self):
        self.put(data=record(source={"type": "argument"}))
        self.run_script("--dry-run", "203.0.113.2", ok=False)
        output = self.run_script("--dry-run", "2001:db8::2")
        self.assertEqual(json.loads(output.stdout)["address"], "2001:db8:0:0:0:0:0:2")

    def test_http_plain_text_and_json_field(self):
        self.put(data=record(source={"type": "http", "url": "https://lookup.invalid/v6", "json_field": "ip"}))
        output = self.run_script("--dry-run")
        self.assertEqual(json.loads(output.stdout)["address"], "2606:4700:0:0:0:0:0:1111")
        self.put(data=record(family="A", source={"type": "http", "url": "https://lookup.invalid/v4"}))
        self.run_script("--dry-run")
        self.assertTrue(all(c["method"] == "GET" for c in self.calls()))

    def test_public_address_validation(self):
        self.put(data=record(source={"type": "argument"}))
        for bad in ["fd00::1", "fe80::1", "2001:::1", "2001::1::2", "2001:db8:0:0:0:0:0:0::", "::ffff:192.0.2.1"]:
            with self.subTest(bad=bad):
                self.run_script("--dry-run", "--ipv6", bad, ok=False)

    def test_disabled_tasks_only_resolved_when_explicit_preview(self):
        r = record(); r["enabled"] = False
        self.put(data=r)
        self.run_script()
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.run_script("--dry-run").stdout, "")
        self.assertIn("wg.example.com", self.run_script("--dry-run", "--task", "wg.example.com").stdout)

    def test_symlink_and_path_traversal_rejected(self):
        external = self.root / "outside.json"; external.write_text(json.dumps(record()))
        local = self.confdir / "wg.example.com.json"
        local.symlink_to(external)
        self.run_script("--check", ok=False)
        self.run_script("edit", "../outside", manager=True, ok=False)

    def test_existing_lock_is_not_removed(self):
        self.put()
        lock = self.root / "conf.d.lock"; lock.mkdir()
        (lock / "pid").write_text("12345")
        self.run_script("--check", ok=False)
        self.assertEqual((lock / "pid").read_text(), "12345")

    def test_import_compact_show_enable_disable_delete(self):
        incoming = self.root / "incoming.json"; incoming.write_text(json.dumps(record(), indent=2))
        self.run_script("import", "wg.example.com", str(incoming), manager=True)
        file = self.confdir / "wg.example.com.json"
        self.assertEqual(len(file.read_text().splitlines()), 1)
        self.assertFalse(json.loads(file.read_text())["enabled"])
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.run_script("enable", "wg.example.com", manager=True, input="yes\n")
        self.assertTrue(json.loads(file.read_text())["enabled"])
        self.run_script("disable", "wg.example.com", manager=True)
        self.assertFalse(json.loads(file.read_text())["enabled"])
        self.run_script("delete", "wg.example.com", manager=True, input="yes\n")
        self.assertFalse(file.exists())
        self.assertEqual(self.calls(), [])

    def test_unified_config_entrypoint(self):
        incoming = self.root / "incoming.json"
        incoming.write_text(json.dumps(record(), indent=2))
        self.run_script("import", "wg.example.com", str(incoming), unified_manager=True)
        result = json.loads((self.confdir / "wg.example.com.json").read_text())
        self.assertFalse(result["enabled"])
        self.run_script("--check")

    def test_list_shows_current_dns_content_and_disable_can_select_by_number(self):
        self.put()
        listing = self.run_script("list", manager=True)
        self.assertIn("序号", listing.stdout)
        self.assertIn("wg.example.com", listing.stdout)
        self.assertIn("2408:8207:6c24:a40:11:32ff:fe29:a81", listing.stdout)
        self.assertIn("启用", listing.stdout)
        self.run_script("disable", manager=True, input="1\n")
        data = json.loads((self.confdir / "wg.example.com.json").read_text())
        self.assertFalse(data["enabled"])

    def test_empty_menu_selection_refreshes_the_list_without_an_exit_option(self):
        self.put()
        result = self.run_script(manager=True, input="\n")
        self.assertNotIn("0 退出", result.stdout + result.stderr)
        self.assertIn("直接回车刷新列表", result.stdout + result.stderr)
        self.assertGreaterEqual(result.stdout.count("已有 DDNS 配置："), 2)

    def test_wizard_create_and_edit(self):
        # Choose existing domain 2 (wg); its only existing family makes AAAA the default.
        answers = "2\n2\n4\nbr0\n0011:32ff:fe29:0a81\nyes\n"
        result = self.run_script("add", manager=True, input=answers)
        self.assertIn("wg.example.com", result.stdout)
        self.assertIn("选择 [2]", result.stderr)
        self.assertIn("4. LAN", result.stderr)
        self.assertIn("选择来源 [2]", result.stderr)
        self.assertNotIn("选择序号或 new", result.stderr)
        self.assertIn("Cloudflare DNS 记录预览", result.stdout)
        self.assertIn("Content: 2001:db8::1", result.stdout)
        self.assertIn("Use existing DNS-only record", result.stdout)
        file = self.confdir / "wg.example.com.json"
        self.assertTrue(json.loads(file.read_text())["enabled"])
        # Keep domain/family/source; change IID; preserve ID and interface.
        edit = self.run_script("edit", "wg.example.com", manager=True, input="\n\n\n0011:32ff:fe29:0a82\nyes\n")
        self.assertIn("选择来源 [4]", edit.stderr)
        data = json.loads(file.read_text())
        self.assertEqual(data["AAAA"]["source"]["iid"], "0011:32ff:fe29:0a82")

    def test_interface_source_lists_only_interfaces_with_the_selected_family(self):
        # router has an existing A record; ppp0 is the sole fixture interface with A.
        result = self.run_script("add", manager=True, input="1\n1\n2\n1\nyes\n")
        self.assertIn("可用的本机 A 网卡", result.stderr)
        self.assertIn("ppp0  203.0.113.9", result.stderr)
        self.assertNotIn("br0", result.stderr)
        data = json.loads((self.confdir / "router.example.com.json").read_text())
        self.assertEqual(data["A"]["source"], {"type": "interface", "interface": "ppp0"})

    def test_http_source_accepts_a_bare_host_and_plain_text_marker(self):
        # Entering lookup.invalid/v4 is normalized to HTTPS; a blank field accepts
        # the displayed plain-text marker (-) and does not write json_field.
        answers = "3\ntest\n1\n3\nlookup.invalid/v4\n\n\nyes\n"
        self.run_script("add", manager=True, input=answers)
        source = json.loads((self.confdir / "test.example.com.json").read_text())["A"]["source"]
        self.assertEqual(source, {
            "type": "http", "url": "https://lookup.invalid/v4", "timeout_seconds": 10,
        })

    def test_wizard_can_create_cloudflare_record_without_entering_id(self):
        # Existing names occupy 1-2; choose final item 3, then enter only a host label.
        answers = "3\nnew\n2\n2\n1\nyes\n"
        result = self.run_script("add", manager=True, input=answers)
        self.assertIn("选择序号:", result.stderr)
        self.assertNotIn("选择序号 [1]", result.stderr)
        self.assertNotIn("hidden.example.com", result.stderr)
        self.assertIn("选择 [3]", result.stderr)
        data = json.loads((self.confdir / "new.example.com.json").read_text())
        self.assertEqual(data["AAAA"]["id"], "created-id")
        self.assertTrue(data["enabled"])
        posts = [c for c in self.calls() if c["method"] == "POST"]
        self.assertEqual(len(posts), 1)
        payload = json.loads(posts[0]["payload"])
        self.assertEqual(payload["name"], "new.example.com")
        self.assertEqual(payload["content"], "2408:8207:6c24:a40:0:0:0:1")
        self.assertFalse(payload["proxied"])
        self.assertIn("Action: Create DNS-only record", result.stdout)

    def test_new_record_can_use_manual_initial_address_when_interface_is_unavailable(self):
        # Simulate preparing router configuration on a computer without Linux ip.
        (self.bindir / "ip").unlink()
        answers = "3\ntest\n1\n2\n1\nppp0\n203.0.113.9\nyes\n"
        result = self.run_script("add", manager=True, input=answers)
        self.assertIn("Content: 203.0.113.9", result.stdout)
        posts = [c for c in self.calls() if c["method"] == "POST"]
        self.assertEqual(len(posts), 1)
        self.assertEqual(json.loads(posts[0]["payload"])["content"], "203.0.113.9")

    def test_domain_name_is_the_new_task_identifier(self):
        self.put("old.example.com", record("old.example.com", "old6"))
        # Select router.example.com; it becomes the local task/file identifier.
        answers = "1\n1\n2\n1\nyes\n"
        result = self.run_script("add", manager=True, input=answers)
        self.assertIn("router.example.com", result.stdout)
        self.assertIn("选择 [3]", result.stderr)
        self.assertNotIn("4. LAN", result.stderr)
        self.assertTrue((self.confdir / "router.example.com.json").is_file())
        self.assertFalse((self.confdir / "RECORD_001.json").exists())

    def test_existing_a_only_domain_defaults_to_a(self):
        self.api.pop("r6")
        self.fixture_files()
        # Select router; accept its A-only default, then configure the A source.
        answers = "1\n\n2\n1\nyes\n"
        result = self.run_script("add", manager=True, input=answers)
        self.assertIn("选择 [1]", result.stderr)
        data = json.loads((self.confdir / "router.example.com.json").read_text())
        self.assertIn("A", data)
        self.assertNotIn("AAAA", data)

    def test_new_domain_rejects_full_name_instead_of_double_suffixing(self):
        before = set(self.confdir.iterdir())
        self.run_script("add", manager=True, input="3\nnew.example.com\n", ok=False)
        self.assertEqual(set(self.confdir.iterdir()), before)

    def test_domain_selection_has_no_default(self):
        self.run_script("add", manager=True, input="\n", ok=False)
        self.assertFalse((self.confdir / "wg.example.com.json").exists())

    def test_add_filters_domains_already_configured_locally(self):
        self.put()
        result = self.run_script("add", manager=True, input="\n", ok=False)
        self.assertIn("router.example.com", result.stderr)
        self.assertNotIn("wg.example.com\n", result.stderr)

    def test_multiple_json_documents_and_injection_rejected(self):
        self.put()
        file = self.confdir / "wg.example.com.json"
        file.write_text(file.read_text() + "\n" + file.read_text())
        self.run_script("--check", ok=False)
        r = record(); r["name"] = "$(touch /tmp/ddns-injected).example.com"
        self.put("wg.example.com", data=r)
        self.run_script("--check", ok=False)
        self.assertEqual(self.calls(), [])

    def test_manager_duplicate_import_does_not_modify_existing(self):
        self.put()
        before = (self.confdir / "wg.example.com.json").read_bytes()
        incoming = self.root / "incoming.json"; incoming.write_text(json.dumps(record()))
        self.run_script("import", "other.example.com", str(incoming), manager=True, ok=False)
        self.assertEqual((self.confdir / "wg.example.com.json").read_bytes(), before)
        self.assertFalse((self.confdir / "other.example.com.json").exists())

    def test_legacy_state_is_not_executed(self):
        self.put()
        (self.root / "state.json").write_text('LAST_IPV6="$(touch /tmp/ddns-state-injection)"\n')
        self.run_script()
        self.assertEqual(len(json.loads((self.root / "state.json").read_text())), 1)

    def test_interface_ambiguity_and_pd_60_are_rejected(self):
        self.put(data=record(source={"type": "interface", "interface": "br0"}))
        self.interfaces["-6:br0"] += "\n2: br0 inet6 2408:8207:6c24:a40::2/64 scope global preferred_lft forever"
        self.fixture_files()
        self.run_script("--dry-run", ok=False)
        self.put()
        self.interfaces["-6:br0"] = "2: br0 inet6 2408:8207:6c24:a40::1/60 scope global preferred_lft forever"
        self.fixture_files()
        self.run_script("--dry-run", ok=False)

    def test_filename_must_match_domain(self):
        self.put()
        (self.confdir / "wg.example.com.json").rename(self.confdir / "renamed.example.com.json")
        self.run_script("--check", ok=False)

    def test_invalid_state_blocks_api_and_is_preserved(self):
        self.put()
        state = self.root / "state.json"
        state.write_text("not a state file")
        self.run_script(ok=False)
        self.assertEqual(state.read_text(), "not a state file")
        self.assertEqual(self.calls(), [])

    def test_unknown_top_level_fields_and_provider_rejected(self):
        for extra in [{"typo": True}, {"provider": "../../external-command"}]:
            r = record(); r.update(extra)
            self.put(data=r)
            self.run_script("--check", ok=False)
        self.assertEqual(self.calls(), [])

    def test_cancel_delete_and_invalid_edit_preserve_original(self):
        self.put()
        file = self.confdir / "wg.example.com.json"
        original = file.read_bytes()
        self.run_script("delete", "wg.example.com", manager=True, input="no\n", ok=False)
        self.assertEqual(file.read_bytes(), original)
        # An invalid source never reaches the commit stage.
        self.run_script("edit", "wg.example.com", manager=True, input="\n\n\ninvalid\n", ok=False)
        self.assertEqual(file.read_bytes(), original)

    def test_http_redirect_and_private_address_rejected(self):
        self.put(data=record(family="A", source={"type": "http", "url": "https://lookup.invalid/v4"}))
        self.http["https://lookup.invalid/v4"] = {"body": "198.51.100.22", "status": 302}
        self.fixture_files()
        self.run_script("--dry-run", ok=False)
        self.http["https://lookup.invalid/v4"] = {"body": "192.168.50.22"}
        self.fixture_files()
        self.run_script("--dry-run", ok=False)


if __name__ == "__main__":
    unittest.main()
