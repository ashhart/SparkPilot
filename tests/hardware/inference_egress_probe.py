"""Run against a disposable probe container; never send prompts or other user data."""
import argparse
import json
import socket
import subprocess
import threading
import urllib.request


def probe(container, port):
    observed = json.loads(subprocess.check_output(['docker', 'inspect', container]))[0]
    networks = list(observed['NetworkSettings']['Networks'].values())
    if len(networks) != 1:
        raise RuntimeError('Probe requires exactly one inference network')
    gateway = networks[0]['Gateway']
    received = []
    finished = threading.Event()
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(('0.0.0.0', 0))
    udp.settimeout(0.25)
    udp_port = udp.getsockname()[1]
    tcp = socket.socket()
    tcp.bind(('0.0.0.0', 0))
    tcp.listen(1)
    tcp.settimeout(0.25)
    tcp_port = tcp.getsockname()[1]

    def listen(sock, datagram):
        try:
            while not finished.is_set():
                try:
                    if datagram:
                        received.append(('udp', sock.recvfrom(64)[0]))
                    else:
                        connection, _ = sock.accept()
                        received.append(('tcp', True))
                        connection.close()
                except TimeoutError:
                    continue
        finally:
            sock.close()

    listeners = [threading.Thread(target=listen, args=(udp, True)),
                 threading.Thread(target=listen, args=(tcp, False))]
    for thread in listeners:
        thread.start()
    script = r'''
import json, socket, sys
socket.setdefaulttimeout(2)
gateway, udp_port, tcp_port = sys.argv[1:]
results = {}
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.sendto(b'sparkpilot-isolation-probe', (gateway, int(udp_port)))
try:
    socket.getaddrinfo('example.com', 443)
    results['external_dns_blocked'] = False
except socket.gaierror:
    results['external_dns_blocked'] = True
for label, host, port in [('host_tcp_blocked',gateway,int(tcp_port)),
                          ('internet_tcp_blocked','1.1.1.1',443),
                          ('ipv6_tcp_blocked','2606:4700:4700::1111',443)]:
    try:
        with socket.create_connection((host, port), timeout=2):
            results[label] = False
    except OSError:
        results[label] = True
print(json.dumps(results))
'''
    try:
        output = subprocess.check_output(['docker', 'exec', container, 'python3', '-c', script,
                                         gateway, str(udp_port), str(tcp_port)], timeout=20)
        results = json.loads(output)
    finally:
        finished.set()
        for thread in listeners:
            thread.join()
    results['host_udp_blocked'] = not any(kind == 'udp' for kind, _ in received)
    results['host_listener_received_nothing'] = not received
    for attempt in range(3):
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=3) as response:
            assert response.status == 200
            if attempt == 1:
                response.read(1)  # Close early, then prove the next request still works.
            else:
                assert response.read()
    results['loopback_http_and_reconnect'] = True
    print(json.dumps(results, sort_keys=True))
    if not all(results.values()):
        raise SystemExit('FAIL: inference boundary permits outbound traffic')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--container', required=True)
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    probe(args.container, args.port)
