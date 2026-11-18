# Shared Zero Trust enrollment adapter. Keep in sync in singbox and sbx.
_zero_trust_enroll() (
    set +x
    umask 077
    local output="$1" dir file
    local upstream='https://raw.githubusercontent.com/BlizzardSaber/zerotrust-warp-masque/7cae14a10eb181538662a6d16fea29c05c47f06d'
    if ! [ -t 0 ]; then printf '请使用交互式 SSH 终端登录 Zero Trust。\n' >&2; exit 1; fi
    if ! command -v python3 openssl curl sha256sum >/dev/null; then
        printf 'Zero Trust 登录需要 python3、openssl、curl 和 sha256sum。\n' >&2; exit 1
    fi
    dir=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$dir"' EXIT
    trap 'exit 1' HUP INT TERM
    for file in zt_login.py zerotrust2wg.py; do
        curl -qfsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 \
            "$upstream/$file" -o "$dir/$file" || exit 1
    done
    ( cd "$dir" && sha256sum -c --status <<'SUMS'
d08cd613b3cc554099b17ffa90b4f3f061be6134714cc88d2442e426190bbe99  zt_login.py
8a6b1aa9bb70f3be116b3643aa172e7d3fde98c817a70436e2cc43c7ad07234b  zerotrust2wg.py
SUMS
    ) || { printf 'Zero Trust 登录组件校验失败，未执行。\n' >&2; exit 1; }
    cat > "$dir/enroll.py" <<'PYTHON' || exit 1
#!/usr/bin/env python3
"""SBX interactive WireGuard enrollment, using pinned Cloudflare login helpers."""
import base64
import getpass
import ipaddress
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import zt_login as login
import zerotrust2wg as wg


def require_origin(url, host):
    u = urllib.parse.urlsplit(url)
    if u.scheme != 'https' or u.netloc != host:
        raise ValueError('Cloudflare 返回了非预期的登录地址，已停止。')


class SameOriginRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, host):
        self.host = host

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require_origin(newurl, self.host)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class TeamLogin(login.AccessLogin):
    def __init__(self, org):
        super().__init__(org)
        self.host = f'{org}.cloudflareaccess.com'
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), SameOriginRedirect(self.host),
            urllib.request.HTTPCookieProcessor(self.jar))
        self.opener.addheaders = [('User-Agent', login.UA)]

    def _open(self, url, data=None):
        require_origin(url, self.host)
        return super()._open(url, data)


def enrollment_token(access, url, html):
    candidates = [cookie.value for cookie in access.jar]
    candidates += login.JWT_RE.findall(html)
    for values in urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).values():
        candidates += values
    for token in candidates:
        claims = login.jwt_payload(token)
        if (isinstance(claims, dict) and claims.get('iss') == access.base
                and claims.get('type') == 'app' and claims.get('warp') is True
                and isinstance(claims.get('exp'), (float, int))
                and claims['exp'] > time.time()):
            return token
    raise ValueError('未收到有效的组织注册令牌，请检查邮箱验证码和设备注册策略。')


def endpoint(response, private_key):
    v4, v6 = wg.pick_addresses(response)
    peers = (response.get("config", {}).get("peers") or response.get("peers") or [])
    public_key = peers[0].get("public_key") if peers else None
    if not isinstance(public_key, str) or len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError('设备返回的 WireGuard 公钥无效。')
    addresses = [str(ipaddress.IPv4Interface(f'{v4}/32'))]
    if v6:
        addresses.append(str(ipaddress.IPv6Interface(f'{v6}/128')))
    remote = {'address': '162.159.193.1', 'port': 2408,
              'public_key': public_key, 'allowed_ips': ['0.0.0.0/0', '::/0']}
    client_id = response.get('config', {}).get('client_id')
    if client_id:
        remote['reserved'] = list(base64.b64decode(client_id, validate=True))
        if len(remote['reserved']) != 3:
            raise ValueError('设备返回的 WireGuard reserved 长度无效。')
    return {'type': 'wireguard', 'tag': 'warp-out', 'mtu': 1280, 'address': addresses,
            'private_key': private_key, 'peers': [remote]}


def main(destination):
    os.umask(0o077)
    if not sys.stdin.isatty():
        raise ValueError('请通过交互式 SSH 终端登录。')
    org = input('Zero Trust 组织名（不含 .cloudflareaccess.com）：').strip().lower()
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', org):
        raise ValueError('组织名无效。')
    email = input('注册邮箱：').strip()
    if not email or '@' not in email:
        raise ValueError('邮箱无效。')
    urllib.request.install_opener(urllib.request.build_opener(
        urllib.request.ProxyHandler({}), SameOriginRedirect('api.cloudflareclient.com')))
    access = TeamLogin(org)
    access.start()
    _, html = access.submit_email(email)
    if not access.parse_code_form(html):
        raise ValueError('组织未返回邮箱验证码表单，请检查是否允许邮箱验证码注册。')
    code = getpass.getpass('邮件验证码（不回显）：').strip()
    if not code:
        raise ValueError('验证码为空。')
    url, html = access.submit_code(code)
    token = enrollment_token(access, url, html)
    private, public = wg.gen_keypair()
    response = wg.register(public, token)
    wg.validate_team_or_cleanup(response)
    Path(destination).write_text(json.dumps(endpoint(response, private)), encoding='utf-8')


if __name__ == '__main__':
    try:
        main(sys.argv[1])
    except (KeyboardInterrupt, EOFError):
        sys.exit('\n已取消。')
    except urllib.error.HTTPError as exc:
        sys.exit(f'Cloudflare 请求失败：HTTP {exc.code}。')
    except wg.TeamTokenError as exc:
        sys.exit(f'Cloudflare 设备注册失败：HTTP {exc.code}。')
    except ValueError:
        sys.exit('输入或 Cloudflare 响应无效，请检查组织名、邮箱验证码及设备注册策略。')
    except Exception:
        sys.exit('无法完成 Cloudflare 登录或导出，原配置未改动。')
PYTHON
    python3 -I -B -c 'import runpy, sys; d = sys.argv.pop(1); sys.path.insert(0, d); runpy.run_path(d + "/enroll.py", run_name="__main__")' "$dir" "$output"
)
