"""One bounded daily recap attempt per minute, only in paired offline runtimes."""

import asyncio
import logging
from uuid import NAMESPACE_URL, uuid5
from threading import Event, Thread

from fastapi import HTTPException
from database import local_daily_recaps as recaps, local_recap_schedule as schedule
from utils.local_transport_auth import load_pairing, local_tunnel_enabled

logger = logging.getLogger(__name__)


def tick(stopped=lambda: False):
    if stopped() or not local_tunnel_enabled():
        return
    uid = load_pairing()['owner_uid']
    claimed = schedule.claim(uid)
    if claimed is None:
        return
    status = 'unavailable'
    try:
        from routers.local_daily_recaps import Generate, generate_recap
        day = schedule.day_window(claimed['next_day'], claimed['timezone'])
        saved = recaps.read(uid, day)
        if saved:
            status = 'existing'
        else:
            captured = recaps.context(uid, day)
            if not captured.sources:
                status = 'empty' if captured.count == 0 else 'sources_unavailable'
            else:
                # A retry of unchanged inputs reuses the publication receipt.
                identity = ':'.join((claimed['revision'], day.date, captured.revision))
                body = Generate(day=day.date, start=day.start, end=day.end,
                                request_id=str(uuid5(NAMESPACE_URL, identity)), revision=captured.revision,
                                provider_binding=claimed['provider_binding'])
                def publication_guard(tx):
                    if stopped():
                        raise recaps.DayChanged()
                    schedule.guard(tx, uid, claimed)
                generate_recap(body, uid, publication_guard)
                status = 'ready'
    except HTTPException as error:
        status = 'changed' if error.status_code == 409 else 'unavailable'
    except Exception:
        # Never log source text, model responses, identifiers or credentials.
        logger.warning('Local daily recap attempt unavailable')
    finally:
        schedule.finish(uid, claimed, status)


class RecapScheduler:
    def __init__(self):
        self._stop = Event()
        self._thread = None

    def start(self):
        self._stop = Event()
        # A bounded provider request must not hold up Firebase export on exit.
        # The stop flag fences publication; an interrupted lease recovers later.
        self._thread = Thread(target=self._run, args=(self._stop,), name='local-daily-recaps', daemon=True)
        self._thread.start()

    def _run(self, stop):
        while not stop.is_set():
            try:
                tick(stop.is_set)
            except Exception:
                logger.warning('Local daily recap scheduler unavailable')
            stop.wait(60)

    async def stop(self):
        self._stop.set()
        if self._thread is not None:
            await asyncio.to_thread(self._thread.join, 5)
