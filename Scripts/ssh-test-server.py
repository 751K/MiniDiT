"""测试用的「相机 SSH 服务」：模仿索尼访问身份验证——只允许键盘交互登录、只用 aes128-ctr、RSA 主机密钥，
direct-tcpip 通道（相机要求转发到 localhost:15740）被转发到 FORWARD_PORT（模拟索尼相机）。

用法：FORWARD_PORT=15741 python3 ssh-test-server.py 用户名 密码
启动后打印一行：READY <SSH 端口> <SHA256 指纹>
"""
import base64, hashlib, os, socket, sys, threading
import paramiko

USER, PASSWORD = sys.argv[1], sys.argv[2]
FORWARD_HOST = os.environ.get("FORWARD_HOST", "127.0.0.1")
FORWARD_PORT = int(os.environ["FORWARD_PORT"])
hostkey = paramiko.RSAKey.generate(2048)


class Server(paramiko.ServerInterface):
    def get_allowed_auths(self, username):
        return "keyboard-interactive"

    def check_auth_interactive(self, username, submethods):
        self.user = username
        q = paramiko.InteractiveQuery("", "")
        q.add_prompt("Password: ", False)
        return q

    def check_auth_interactive_response(self, responses):
        ok = getattr(self, "user", None) == USER and list(responses) == [PASSWORD]
        print("auth", "OK" if ok else "FAIL", flush=True)
        return paramiko.AUTH_SUCCESSFUL if ok else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "direct-tcpip" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        print("direct-tcpip", destination, flush=True)
        # 只放行相机真正会用的目标。
        if destination[1] != 15740:
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        return paramiko.OPEN_SUCCEEDED


def pump(chan):
    sock = socket.create_connection((FORWARD_HOST, FORWARD_PORT))
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def up():
        try:
            while True:
                d = chan.recv(65536)
                if not d:
                    break
                sock.sendall(d)
        finally:
            try: sock.shutdown(socket.SHUT_WR)
            except OSError: pass

    def down():
        try:
            while True:
                d = sock.recv(65536)
                if not d:
                    break
                chan.sendall(d)
        finally:
            chan.close()

    threading.Thread(target=up, daemon=True).start()
    threading.Thread(target=down, daemon=True).start()


def handle(conn):
    t = paramiko.Transport(conn)
    t.get_security_options().ciphers = ("aes128-ctr",)
    t.add_server_key(hostkey)
    try:
        t.start_server(server=Server())
    except Exception as e:
        print("handshake failed", e, flush=True)
        return
    while t.is_active():
        ch = t.accept(1)
        if ch is not None:
            pump(ch)


ls = socket.socket()
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind(("127.0.0.1", 0))
ls.listen(8)
fp = "SHA256:" + base64.b64encode(hashlib.sha256(hostkey.asbytes()).digest()).decode().rstrip("=")
print(f"READY {ls.getsockname()[1]} {fp}", flush=True)
while True:
    c, _ = ls.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
