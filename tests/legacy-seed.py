"""Create a version-2 panel fixture using its actual SQLite schema."""

import json
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as db:
    db.execute('DELETE FROM settings WHERE key IN ("webListen","webPort","webBasePath","subEnable")')
    db.executemany('INSERT INTO settings(key,value) VALUES(?,?)', [
        ('webListen','0.0.0.0'), ('webListen','127.0.0.1'), ('webPort','24681'),
        ('webBasePath','/legacy-panel/'), ('subEnable','true'),
    ])
    transports = [
        ('vless', 24680, 'legacy-vless', {'decryption': 'none', 'encryption': 'none', 'clients': [{
            'id': '11111111-1111-4111-8111-111111111111', 'email': 'legacy-vless',
            'enable': True, 'expiryTime': 0, 'totalGB': 0,
        }]}, {'network': 'xhttp', 'security': 'none', 'xhttpSettings': {
            'path': '/legacy/xhttp/', 'mode': 'stream-one', 'host': 'test.example.com',
            'xPaddingObfsMode': True, 'xPaddingPlacement': 'header', 'xPaddingMethod': 'tokenish',
            'xPaddingHeader': 'X-Legacy-Pad', 'xPaddingKey': 'X-Legacy-Key',
            'sessionIDPlacement': 'header', 'sessionIDKey': 'X-Legacy-Session',
            'seqPlacement': 'header', 'seqKey': 'X-Legacy-Sequence',
        }}),
        ('hysteria', 443, 'legacy-hy2', {'version': 2, 'clients': [{
            'id': '22222222-2222-4222-8222-222222222222', 'auth': 'legacy-hy2-auth',
            'email': 'legacy-hy2', 'enable': True, 'expiryTime': 0, 'totalGB': 0,
        }]}, {'network': 'hysteria', 'security': 'tls', 'hysteriaSettings': {'version': 2},
              'tlsSettings': {'serverName': 'test.example.com', 'alpn': ['h3']}}),
    ]
    for protocol, port, tag, settings, stream in transports:
        result = db.execute(
            'INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) '
            'VALUES(1,42,77,0,?,1,0,"0.0.0.0",?,?,?,?,?,?)',
            (tag, port, protocol, json.dumps(settings), json.dumps(stream), tag,
             json.dumps({'enabled': True, 'destOverride': ['http','tls','quic']})),
        )
        db.execute('INSERT INTO client_traffics(inbound_id,enable,email,up,down,total,expiry_time,reset) VALUES(?,1,?,42,77,0,0,0)',
                   (result.lastrowid, tag))
