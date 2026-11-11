"""Verify the certificate actually served on both local TLS transports."""

import asyncio
import socket
import ssl
import sys
from pathlib import Path

sys.path.insert(0, "/usr/local/lib/vpn-script/probe-packages")

from aioquic.asyncio.client import connect
from aioquic.quic.configuration import QuicConfiguration
from cryptography.hazmat.primitives import hashes
from cryptography import x509


async def probe(domain, certificate):
    expected = x509.load_pem_x509_certificate(Path(certificate).read_bytes()).fingerprint(hashes.SHA256())
    context = ssl.create_default_context()
    with socket.create_connection(("127.0.0.1", 443), timeout=5) as tcp:
        with context.wrap_socket(tcp, server_hostname=domain) as tls:
            peer = x509.load_der_x509_certificate(tls.getpeercert(binary_form=True))
            if peer.fingerprint(hashes.SHA256()) != expected:
                raise ValueError("TCP certificate mismatch")
    configuration = QuicConfiguration(alpn_protocols=["h3"], server_name=domain)
    configuration.load_verify_locations(cafile="/etc/ssl/certs/ca-certificates.crt", capath="/etc/ssl/certs")
    async with connect("127.0.0.1", 443, configuration=configuration) as connection:
        # aioquic exposes the authenticated leaf through its TLS context.
        peer = connection._quic.tls._peer_certificate
        if peer is None or peer.fingerprint(hashes.SHA256()) != expected:
            raise ValueError("QUIC certificate mismatch")


def main():
    if len(sys.argv) != 3:
        print("Usage: certificate_probe.py DOMAIN FULLCHAIN", file=sys.stderr)
        return 1
    try:
        asyncio.run(asyncio.wait_for(probe(*sys.argv[1:]), timeout=12))
    except Exception:
        print("vpn-script: TCP or QUIC certificate verification failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
