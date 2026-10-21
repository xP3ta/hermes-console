"""The flap proxy's per-window numbers are observational only.

Run: python3 -m unittest discover -s tool/e2e -p 'test_*.py'

``ws_opens_by_window`` counts upgrade requests per cut window (the window of a
request is the number of cuts made before it) and ``severed_ws`` counts the
live WebSockets a cut tore down. Neither may change what the proxy does.
"""

from __future__ import annotations

import asyncio
import unittest

from flap_proxy import Proxy

UPGRADE = b"GET /api/ws HTTP/1.1\r\nHost: x\r\n\r\n"


async def _dial(port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(UPGRADE)
    await writer.drain()
    return reader, writer


async def _upstream(reader, writer):
    while chunk := await reader.read(65536):
        writer.write(chunk)
        await writer.drain()
    writer.close()


class FlapProxyWindows(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.up = await asyncio.start_server(_upstream, "127.0.0.1", 0)
        port = self.up.sockets[0].getsockname()[1]
        self.proxy = Proxy({"dash": ("127.0.0.1", port)})
        await self.proxy.start()
        self.port = self.proxy.listen["dash"][1]

    async def asyncTearDown(self):
        self.up.close()
        for entry in self.proxy.listen.values():
            if entry[2] is not None:
                entry[2].close()

    async def test_opens_are_counted_in_the_window_they_arrive_in(self):
        _, first = await _dial(self.port)
        await asyncio.sleep(0.05)
        await self.proxy.command("rst")
        await self.proxy.command("pass")
        _, second = await _dial(self.port)
        _, third = await _dial(self.port)
        await asyncio.sleep(0.05)
        stats = (await self.proxy.command("stats"))
        self.assertEqual(stats["ws_opens_by_window"], {"0": 1, "1": 2})
        self.assertEqual(stats["by_path"]["GET /api/ws"], 3)
        for w in (first, second, third):
            w.close()

    async def test_a_cut_reports_the_live_websockets_it_severed(self):
        _, a = await _dial(self.port)
        _, b = await _dial(self.port)
        await asyncio.sleep(0.05)
        stats = await self.proxy.command("rst")
        self.assertEqual(stats["severed_ws"], 2)
        again = await self.proxy.command("pass")
        self.assertEqual(again["severed_ws"], 2)  # pass severs nothing
        a.close()
        b.close()

    async def test_a_cut_with_nothing_alive_severs_nothing(self):
        stats = await self.proxy.command("rst")
        self.assertEqual(stats["cuts"], 1)
        self.assertEqual(stats["severed_ws"], 0)

    async def test_reset_starts_a_new_measure(self):
        _, a = await _dial(self.port)
        await asyncio.sleep(0.05)
        await self.proxy.command("rst")
        stats = await self.proxy.command("reset")
        self.assertEqual(stats["severed_ws"], 0)
        self.assertEqual(stats["ws_opens_by_window"], {})
        a.close()


if __name__ == "__main__":
    unittest.main()
