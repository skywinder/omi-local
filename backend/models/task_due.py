"""Date precision on the upstream Omi task wire."""

from datetime import date as Date, datetime, time, timezone
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator


class TaskDue(BaseModel):
    model_config = ConfigDict(extra='forbid', frozen=True)

    kind: Literal['none', 'date', 'instant', 'unresolved']
    date: str | None = Field(default=None, pattern=r'^\d{4}-\d{2}-\d{2}$')
    timezone: str | None = Field(default=None, max_length=128)
    instant: AwareDatetime | None = None
    expression: str | None = Field(default=None, max_length=512)
    year_basis: Literal['spoken', 'source_relative', 'next_future_occurrence'] | None = None
    reason: str | None = Field(default=None, max_length=128)

    @model_validator(mode='after')
    def validate_precision(self):
        if self.kind == 'date':
            if not self.date or not self.timezone or self.instant is not None:
                raise ValueError('date due requires a local date and timezone, without an instant')
            Date.fromisoformat(self.date)
        elif self.kind == 'instant':
            if self.instant is None or not self.timezone or self.date is not None:
                raise ValueError('instant due requires an instant and timezone')
        elif self.date is not None or self.instant is not None:
            raise ValueError('none/unresolved due cannot carry a date or instant')
        if self.kind == 'unresolved' and not self.reason:
            raise ValueError('unresolved due requires a reason')
        if self.timezone:
            try:
                ZoneInfo(self.timezone)
            except (ValueError, ZoneInfoNotFoundError) as error:
                raise ValueError('Invalid IANA timezone') from error
        return self

    def reminder_at(self) -> datetime | None:
        if self.kind == 'instant':
            return self.instant.astimezone(timezone.utc)
        if self.kind == 'date':
            scheduled = datetime.combine(Date.fromisoformat(self.date), time(9), tzinfo=ZoneInfo(self.timezone))
            return scheduled.astimezone(timezone.utc)
        return None

    @classmethod
    def from_task(cls, row) -> 'TaskDue | None':
        if row.get('due') is not None:
            return cls.model_validate(row['due'])
        if row.get('due_at') is not None:
            return cls(kind='instant', instant=row['due_at'], timezone='UTC')
        return None
