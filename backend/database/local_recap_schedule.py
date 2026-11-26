"""Owner-scoped, opt-in daily recap cursor and transaction-fenced worker lease."""

from datetime import date, datetime, time, timedelta, timezone
from uuid import uuid4
from zoneinfo import ZoneInfo

from google.cloud import firestore
from database._client import db, run_transactional
from database.local_daily_recaps import Day, DayChanged

UTC = timezone.utc


def now():
    return datetime.now(UTC)


def _ref(uid):
    return db.collection('users').document(uid).collection('local_settings').document('daily_recaps')


def defaults():
    return {'revision': '', 'enabled': False, 'timezone': 'UTC', 'hour': 9, 'minute': 0,
            'status': 'disabled', 'next_day': None, 'last_day': None, 'last_run': None}


def read(uid):
    return _ref(uid).get(retry=None, timeout=6).to_dict() or defaults()


def public(row):
    return {key: row.get(key) for key in (*defaults(), 'model', 'host', 'retry_after')}


def day_window(day, zone):
    value, tz = date.fromisoformat(day), ZoneInfo(zone)
    return Day(day, datetime.combine(value, time.min, tz).astimezone(UTC),
               datetime.combine(value + timedelta(days=1), time.min, tz).astimezone(UTC))


@firestore.transactional
def _configure(tx, uid, body, instant):
    ref = _ref(uid)
    old = ref.get(transaction=tx, timeout=6).to_dict() or defaults()
    if old.get('request_id') == body['request_id']:
        if old.get('request_body') != body:
            raise DayChanged()
        return old
    if old['revision'] != body['revision']:
        raise DayChanged()
    row = {**old, **{key: body[key] for key in ('enabled', 'timezone', 'hour', 'minute',
                                               'provider_binding', 'model', 'host')}}
    reset = body['enabled'] and (not old['enabled'] or old['timezone'] != body['timezone'])
    if reset:
        row['next_day'] = instant.astimezone(ZoneInfo(body['timezone'])).date().isoformat()
    row.update(revision=str(uuid4()), request_id=body['request_id'], request_body=body,
               status='waiting' if body['enabled'] else 'disabled', lease=None, retry_after=None, failures=0)
    tx.set(ref, row)
    return row


def configure(uid, body):
    return run_transactional(db, _configure, uid, body, now())


@firestore.transactional
def _claim(tx, uid, instant):
    ref = _ref(uid)
    row = ref.get(transaction=tx, timeout=6).to_dict()
    if not row or not row['enabled']:
        return None
    if row.get('retry_after') and row['retry_after'] > instant:
        return None
    if row.get('lease') and row['lease']['until'] > instant:
        return None
    local = instant.astimezone(ZoneInfo(row['timezone']))
    scheduled_day = date.fromisoformat(row['next_day']) + timedelta(days=1)
    # Compare wall times: a missing DST hour runs on the first later tick; a
    # repeated hour is consumed only once by the persistent day cursor.
    if local.date() < scheduled_day or (local.date() == scheduled_day and
                                       (local.hour, local.minute) < (row['hour'], row['minute'])):
        return None
    row = {**row, 'lease': {'id': str(uuid4()), 'until': instant + timedelta(minutes=10)}, 'status': 'running'}
    tx.set(ref, row)
    return row


def claim(uid):
    return run_transactional(db, _claim, uid, now())


def guard(tx, uid, claimed):
    current = _ref(uid).get(transaction=tx, timeout=6).to_dict() or {}
    if (not current.get('enabled') or current.get('revision') != claimed['revision']
            or current.get('lease') != claimed['lease'] or claimed['lease']['until'] <= now()):
        raise DayChanged()


@firestore.transactional
def _finish(tx, uid, claimed, status, instant):
    ref = _ref(uid)
    row = ref.get(transaction=tx, timeout=6).to_dict() or {}
    if row.get('revision') != claimed['revision'] or row.get('lease') != claimed['lease']:
        return
    success = status in {'ready', 'empty', 'existing'}
    failures = 0 if success else min(row.get('failures', 0) + 1, 8)
    row.update(lease=None, status=status, failures=failures, last_run=instant,
               retry_after=None if success else instant + timedelta(minutes=min(5 * 2 ** (failures - 1), 360)))
    if success:
        row['last_day'] = claimed['next_day']
        row['next_day'] = (date.fromisoformat(claimed['next_day']) + timedelta(days=1)).isoformat()
    tx.set(ref, row)


def finish(uid, claimed, status):
    run_transactional(db, _finish, uid, claimed, status, now())
