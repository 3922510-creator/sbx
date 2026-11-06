import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "sbx.sh"


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
