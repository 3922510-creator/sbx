import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def setUpModule():
    global SCRIPT
    output = tempfile.TemporaryDirectory()
    unittest.addModuleCleanup(output.cleanup)
    SCRIPT = Path(output.name) / "sbx"
    subprocess.run(["bash", str(ROOT / "tools/build.sh"), str(SCRIPT)], check=True, timeout=10)


@unittest.skipUnless(shutil.which("jq"), "jq is required")
class TestWarp(unittest.TestCase):
    def run_shell(self, body, *args, input=None):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; shift; ' + body, "bash", str(SCRIPT), *args],
            input=input, capture_output=True, text=True, timeout=8,
        )

    def test_registration_requires_real_addresses_and_peer_key(self):
        cmd = '_warp_registration_endpoint sample-key'
        invalid = self.run_shell(cmd, input='{"errors": []}')
        self.assertNotEqual(invalid.returncode, 0)
        response = {"config": {
            "interface": {"addresses": {"v4": "172.16.0.2", "v6": "2606:4700::2"}},
            "peers": [{"public_key": "a" * 43 + "="}],
        }}
        result = self.run_shell(cmd, input=json.dumps(response))
        self.assertEqual(result.returncode, 0, result.stderr)
        endpoint = json.loads(result.stdout)
        self.assertEqual(endpoint["address"], ["172.16.0.2/32", "2606:4700::2/128"])
        self.assertEqual(endpoint["private_key"], "sample-key")

    def test_sync_keeps_other_rules_and_skips_deleted_nodes(self):
        ai = {"outbound": "warp-out", "rule_set": "geosite-ai"}
        with tempfile.TemporaryDirectory() as d:
            config, state = Path(d) / "config", Path(d) / "state"
            config.write_text(json.dumps({"route": {"rules": [ai, {"inbound": ["old"], "outbound": "warp-out"}]}}))
            state.write_text(json.dumps({"nodes": {"active": {}}, "warp_nodes": ["active", "old"], "warp_custom_domains": ["example.com"]}))
            result = self.run_shell('_sync_warp_rules "$1" "$2"', str(config), str(state))
        self.assertEqual(result.returncode, 0, result.stderr)
        private, kept, domain, node = json.loads(result.stdout)["route"]["rules"]
        self.assertEqual(private["outbound"], "direct")
        self.assertEqual(kept, ai)
        self.assertEqual(domain["domain_suffix"], ["example.com"])
        self.assertEqual(node["inbound"], ["active"])

    def test_failed_restart_restores_config_and_does_not_commit_state(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_shell(r'''
                set -e
                CONFIG_FILE="$1/config"; STATE_FILE="$1/state"; BACKUP_DIR="$1/backups"
                BIN_FILE=/bin/true; INIT_SYS=systemd
                mkdir "$BACKUP_DIR"
                printf '%s\n' '{"old": true}' > "$CONFIG_FILE"
                cp "$CONFIG_FILE" "$STATE_FILE"
                printf '%s\n' '{"new": true}' > "$1/candidate"
                cp "$1/candidate" "$1/state-candidate"
                sbx_svc_action() { jq -e .old "$CONFIG_FILE" >/dev/null; }
                systemctl() { return 0; }
                ! sbx_apply_config_safe "$1/candidate" "$1/state-candidate"
                jq -e .old "$CONFIG_FILE" "$STATE_FILE"
                test ! -e "$1/state-candidate"
            ''', d)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failed_download_keeps_installed_core(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_shell(r'''
                set -e
                BIN_FILE="$1/sing-box"; CONFIG_FILE="$1/config"
                printf '%s\n' 'existing core' > "$BIN_FILE"
                chmod +x "$BIN_FILE"
                curl() {
                    if [[ "$*" == *api.github.com* ]]; then
                        printf '%s\n' '{"tag_name": "v1.14.4"}'
                    else
                        return 1
                    fi
                }
                ! install_singbox_bin update
                test -x "$BIN_FILE" && grep -qx 'existing core' "$BIN_FILE"
            ''', d)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which("sing-box"), "sing-box is required")
    def test_probe_uses_ephemeral_socks_and_requires_warp_flag(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_shell(r'''
                set -e
                BIN_FILE="$2"
                CONFIG_FILE="$1/config"
                printf '%s\n' '{"outbounds":[{"type":"direct","tag":"warp-out"}]}' > "$CONFIG_FILE"
                curl() {
                    [[ "$*" =~ socks5h://127\.0\.0\.1:[1-9][0-9]+ && "$*" == *--noproxy* ]] || return 1
                    printf 'ip=198.51.100.5\ncolo=SJC\nwarp=%s\n' "$trace_flag"
                }
                trace_flag=off; ! _probe_warp
                trace_flag=on; _probe_warp
            ''', d, shutil.which("sing-box"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("未确认流量经过 WARP", result.stderr)
        self.assertIn("198.51.100.5", result.stdout)


class TestSBX(unittest.TestCase):
    def test_syntax(self):
        res = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"Syntax error: {res.stderr}")

    def test_non_interactive_exit(self):
        # 模拟管道输入 0 直接退出
        res = subprocess.run(
            ["bash", str(SCRIPT)],
            input="0\n",
            capture_output=True,
            text=True,
            env={"TERM": "dumb", "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
        )
        self.assertEqual(res.returncode, 0)
        self.assertIn("感谢使用", res.stdout)
        self.assertIn("SBX", res.stdout)
        self.assertIn("系统维护", res.stdout)
        self.assertIn("网络优化与安全", res.stdout)
        self.assertIn("Sing-box 代理", res.stdout)

    @unittest.skipUnless(os.geteuid() == 0, "installer requires root")
    def test_installer_run_uses_local_sources(self):
        result = subprocess.run(
            ["bash", str(ROOT / "install.sh"), "--run"], input="0\n",
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("感谢使用", result.stdout)

    @unittest.skipUnless(os.geteuid() == 0, "installer requires root")
    def test_installer_run_builds_downloaded_snapshot(self):
        with tempfile.TemporaryDirectory() as d:
            temp = Path(d)
            install = temp / "install.sh"
            shutil.copyfile(ROOT / "install.sh", install)
            archive = temp / "snapshot.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(ROOT / "src", arcname="sbx-main/src")
                tar.add(ROOT / "tools/build.sh", arcname="sbx-main/tools/build.sh")
            stub = temp / "curl"
            stub.write_text('#!/usr/bin/env bash\n[[ "$*" == *codeload.github.com* && "${@: -2:1}" == -o ]] || exit 1\ncp -- "$TEST_ARCHIVE" "${@: -1}"\n')
            stub.chmod(0o755)
            result = subprocess.run(
                ["bash", "-c", 'bash <(cat "$1") --run', "bash", str(install)],
                input="0\n", capture_output=True, text=True, timeout=10,
                env={**os.environ, "PATH": f"{temp}:{os.environ['PATH']}", "TEST_ARCHIVE": str(archive)},
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("感谢使用", result.stdout)

    def test_isolation_from_legacy(self):
        content = SCRIPT.read_text(encoding="utf-8")
        # 确保快捷指令是 sbx
        self.assertIn('SHORTCUT_PATH="/usr/local/bin/sbx"', content)
        # 确保配置根路径是 /etc/sbx
        self.assertIn('SBX_ROOT="/etc/sbx"', content)
        # 确保服务名是 sbx.service
        self.assertIn('SERVICE_SYSTEMD="/etc/systemd/system/sbx.service"', content)

    def test_uninstall_coverage(self):
        content = SCRIPT.read_text(encoding="utf-8")
        # 卸载逻辑必须覆盖服务、配置、快捷命令、sysctl
        self.assertIn('rm -rf "$SBX_ROOT"', content)
        self.assertIn('rm -f "$SHORTCUT_PATH"', content)
        self.assertIn('rm -f "$SERVICE_SYSTEMD"', content)
        self.assertIn('rm -f "$TCP_SYSCTL_CONF"', content)


if __name__ == "__main__":
    unittest.main()
