"""Tri dedicated server: private duels, exact sizes, turn rules and restart."""
import tempfile
import time
from pathlib import Path
from test_internet import Client
from test_forfeit_server import Server, join, close_all

for size in (6, 12):
    with tempfile.TemporaryDirectory() as folder:
        server = Server(state_file=Path(folder)/'rooms.json').start()
        clients = []
        try:
            a = Client(server.port); clients.append(a)
            a.send({'type':'create','name':'Alice','tri_cards':size})
            aw = a.until('welcome')
            assert a.until('lobby')['data']['tri_cards'] == size
            b, bw = join(server, aw['code'], 'Bob'); clients.append(b)
            c = Client(server.port); clients.append(c)
            c.send({'type':'join','code':aw['code'],'name':'Third'})
            assert c.until('error')['fatal']
            a.send({'type':'start'})
            first = a.until('state')['data']; second = b.until('state')['data']
            assert first['variant'] == 'tri' and first['tri_goal'] == (2 if size==6 else 3)
            assert len(first['hand']) == len(second['hand']) == size
            assert len(first['players']) == 2 and not first['winning_tris']
            assert not any('hand' in player for player in first['players'])
            assert not set(first['hand']) & set(second['hand'])
            a.send({'type':'action','action':{'type':'discard','card':first['hand'][0]}})
            assert 'Piochez' in a.until('error')['message']
            time.sleep(.06)
            a.send({'type':'action','action':{'type':'draw','source':'deck'}})
            drawn = a.until('state')['data']; b.until('state')
            assert len(drawn['hand'])==size+1 and drawn['phase']=='play' and not drawn['melds']
            time.sleep(.06)
            a.send({'type':'action','action':{'type':'meld','cards':drawn['hand'][:3]}})
            assert 'main' in a.until('error')['message']
            port = server.port
            server.stop(); close_all(clients); clients=[]
            server = Server(state_file=Path(folder)/'rooms.json',port=port).start()
            a, _ = join(server, aw['code'],token=aw['token']); clients.append(a)
            restored = a.until('state')['data']
            assert restored['hand'] == drawn['hand'] and restored['variant']=='tri'
            b, _ = join(server, aw['code'],token=bw['token']); clients.append(b)
            assert b.until('state')['data']['hand']==second['hand']
            a.until('state',lambda m: not m['data']['paused'])
            b.send({'type':'leave'})
            won = a.until('state',lambda m: m['data']['winner']==0)['data']
            assert won['win_by_forfeit'] and won['match_result']['winners']==[0]
        finally:
            close_all(clients); server.stop()
print('PASS: Tri 6/12 private duels, rejection of third player, turn validation, restart and forfeit')
