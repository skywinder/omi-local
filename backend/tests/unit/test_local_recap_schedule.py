"""Behavioral schedule contracts with a controllable Firestore transaction seam."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from database import local_recap_schedule as schedule, local_daily_recaps as recaps
from utils import local_recap_scheduler as scheduler

UTC = timezone.utc


class Store:
    def __init__(self):
        self.data = None
        self.instant = datetime(2026, 3, 28, 12, tzinfo=UTC)

    def get(self, **kwargs):
        return SimpleNamespace(to_dict=lambda: deepcopy(self.data))

    def set(self, ref, row):
        self.data = deepcopy(row)


@pytest.fixture
def store(monkeypatch):
    value = Store()
    monkeypatch.setattr(schedule, '_ref', lambda uid: value)
    monkeypatch.setattr(schedule, 'now', lambda: value.instant)
    monkeypatch.setattr(schedule, 'run_transactional', lambda db, fn, *args: fn.to_wrap(value, *args))
    monkeypatch.setattr(scheduler, 'local_tunnel_enabled', lambda: True)
    monkeypatch.setattr(scheduler, 'load_pairing', lambda: {'owner_uid': 'fixture-owner'})
    return value


def settings():
    return dict(request_id='00000000-0000-4000-8000-000000000001', revision='',
                enabled=True, timezone='Europe/Berlin', hour=9, minute=0,
                provider_binding='a' * 64, model='fixture-model', host='fixture.invalid')


def test_default_off_opt_in_cursor_idempotence_and_conflict(store):
    assert schedule.read('owner')['enabled'] is False
    assert schedule.claim('owner') is None
    row = schedule.configure('owner', settings())
    assert row['next_day'] == '2026-03-28'
    assert schedule.configure('owner', settings()) == row
    with pytest.raises(recaps.DayChanged):
        schedule.configure('owner', {**settings(), 'minute': 30})
    assert schedule.claim('owner') is None
    store.instant = datetime(2026, 3, 29, 6, 59, tzinfo=UTC)
    assert schedule.claim('owner') is None
    store.instant += timedelta(minutes=1)
    claimed = schedule.claim('owner')
    assert claimed['status'] == 'running'
    assert schedule.claim('owner') is None
    schedule.finish('owner', claimed, 'ready')
    assert store.data['next_day'] == '2026-03-29'
    assert schedule.claim('owner') is None


def test_dst_windows_and_missing_hour(store):
    for day, hours in [('2026-03-29', 23), ('2026-10-25', 25)]:
        window = schedule.day_window(day, 'Europe/Berlin')
        assert window.end - window.start == timedelta(hours=hours)
    schedule.configure('owner', {**settings(), 'hour': 2, 'minute': 30})
    store.instant = datetime(2026, 3, 29, 1, tzinfo=UTC)
    assert schedule.claim('owner') is not None


def test_expired_worker_disable_and_late_finish(store):
    row = schedule.configure('owner', settings())
    store.instant += timedelta(days=1)
    old = schedule.claim('owner')
    schedule.guard(store, 'owner', old)
    store.instant += timedelta(minutes=11)
    with pytest.raises(recaps.DayChanged):
        schedule.guard(store, 'owner', old)
    new = schedule.claim('owner')
    with pytest.raises(recaps.DayChanged):
        schedule.guard(store, 'owner', old)
    schedule.finish('owner', old, 'ready')
    assert store.data['lease'] == new['lease']
    schedule.configure('owner', {**settings(), 'revision': row['revision'], 'request_id': 'disable', 'enabled': False})
    with pytest.raises(recaps.DayChanged):
        schedule.guard(store, 'owner', new)
    schedule.finish('owner', new, 'ready')
    assert store.data['status'] == 'disabled'
    assert store.data['next_day'] == '2026-03-28'


def test_restart_catches_up_one_day_and_failure_backoff(store):
    schedule.configure('owner', settings())
    store.instant += timedelta(days=5)
    first = schedule.claim('owner')
    assert first['next_day'] == '2026-03-28'
    schedule.finish('owner', first, 'unavailable')
    assert schedule.claim('owner') is None
    store.instant += timedelta(minutes=5)
    retry = schedule.claim('owner')
    assert retry['next_day'] == first['next_day']
    schedule.finish('owner', retry, 'empty')
    assert schedule.claim('owner')['next_day'] == '2026-03-29'


def test_schedule_edit_conflicts_and_timezone_rebases(store):
    row = schedule.configure('owner', settings())
    with pytest.raises(recaps.DayChanged):
        schedule.configure('owner', {**settings(), 'request_id': 'another'})
    store.instant += timedelta(days=3)
    updated = schedule.configure('owner', {**settings(), 'request_id': 'another',
                                           'revision': row['revision'], 'timezone': 'Asia/Tokyo'})
    assert updated['next_day'] == '2026-03-31'
    assert updated['revision'] != row['revision']


def test_existing_recap_is_never_regenerated(store, monkeypatch):
    import sys
    monkeypatch.setitem(sys.modules, 'routers.local_daily_recaps', SimpleNamespace(Generate=None, generate_recap=None))
    schedule.configure('fixture-owner', settings())
    store.instant += timedelta(days=1)
    monkeypatch.setattr(recaps, 'read', lambda *args: {'headline': 'Manual result'})
    scheduler.tick()
    assert store.data['status'] == 'existing'
    assert store.data['next_day'] == '2026-03-29'


def test_publication_preserves_even_legacy_manual_recap(monkeypatch):
    called = []
    transaction = SimpleNamespace(set=lambda *args: called.append('write'))
    monkeypatch.setattr(recaps, '_recap', lambda *args: SimpleNamespace(get=lambda **kw:
        SimpleNamespace(to_dict=lambda: {'headline': 'Legacy manual recap'})))
    with pytest.raises(recaps.DayChanged):
        recaps._publish.to_wrap(transaction, 'owner', None, None, {}, 'new', 'fingerprint',
                                lambda tx: called.append('guard'))
    assert called == ['guard']
