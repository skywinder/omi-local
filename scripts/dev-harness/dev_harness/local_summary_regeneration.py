"""Regenerate one summary using the explicitly selected harness provider and template."""

import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from time import monotonic
from urllib.parse import urlsplit

from . import local_pipeline
from .local_providers import SettingsError, atomic_json, validate_summary_templates
from .local_provider_http import validate_url


def _provider(profile):
    settings = profile['settings']
    return {
        'binding': hashlib.sha256(json.dumps(profile, sort_keys=True).encode()).hexdigest(),
        'name': profile['name'],
        'model': settings['model'],
        'host': urlsplit(validate_url(settings['base_url'])).netloc,
    }


def options(registry):
    catalog, profiles, default = registry.summary_choices()
    providers = [_provider(profile) for profile in profiles]
    return {
        **catalog,
        'templates': [
            {**row, 'digest': hashlib.sha256(row['prompt'].encode()).hexdigest()} for row in catalog['templates']
        ],
        'providers': providers,
        'default_provider_binding': next(
            (provider['binding'] for p, provider in zip(profiles, providers) if p['id'] == default), None,
        ),
    }


def prepare(registry, body):
    catalog, profiles, _ = registry.summary_choices()
    profile = next((p for p in profiles if _provider(p)['binding'] == body.get('provider_binding')), None)
    template = next((t for t in catalog['templates'] if t['id'] == body.get('template_id')), None)
    if profile is None or template is None:
        raise SettingsError('Summary provider or template changed.', status=409)
    if hashlib.sha256(template['prompt'].encode()).hexdigest() != body.get('template_digest'):
        raise SettingsError('Summary template changed.', status=409)
    template = {**template, 'prompt': body.get('prompt')}
    validate_summary_templates([template], template['id'])
    return {**profile, 'template': template}


def regenerate(registry, body):
    profile = prepare(registry, body)
    transcript = body.get('transcript')
    if not isinstance(transcript, str) or not transcript.strip() or len(transcript) > 120_000:
        raise SettingsError('Invalid transcript for summary.')
    try:
        provider = _provider(profile)
        with TemporaryDirectory(prefix='summary-', dir=registry.root) as temp:
            summary = local_pipeline.summarize_text(
                profile, registry.key(profile), transcript,
                Path(temp), atomic_json, deadline=monotonic() + 205, sourced=body.get('numbered_sources') is True,
            )
    except (OSError, ValueError):
        raise SettingsError('Summary inference failed.', status=503) from None
    return {**summary, 'model': provider['model'], 'template_name': profile['template']['name']}
