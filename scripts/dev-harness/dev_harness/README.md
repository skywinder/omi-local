# Local harness boundaries

`config` and `safety` resolve the owned instance, its loopback ports and private
state. `cli` owns supervised processes; commands must validate ownership before
stopping them. The standalone Mac workflow is described in `docs/START.md`.

The provider settings subsystem uses these boundaries:

- `local_providers`: private drafts, effective snapshots, optimistic revisions
  and separately stored credential versions. It never handles audio.
- `local_provider_api` and `local_provider_probe`: same-origin library operations
  and metadata checks. `local_provider_http` enforces explicit destinations,
  no redirects/proxy inheritance, bounded metadata reads and sanitized errors.
- `local_stt_watch` pins a pipeline per admitted recording. `local_stt` owns
  WAV provenance, the inference lock and backend import; `local_pipeline` caches
  completed STT/diarization/summary stages without switching providers on failure.
- `local_provider_relay` owns external Live connections. Backend only sees
  loopback; a cross-process session gate covers activation and EOF drain.
- `local_library` projects recording artifacts and serves browser assets.
  `local_library_runtime` observes current processing without retaining drafts
  in diagnostic history. Settings and transcript endpoints have different data
  contracts; credentials never appear in either response.

Existing jobs and result identities remain readable. Model installations,
remote credentials, recordings and execution artifacts stay outside Git.
Tests are registered in the repository Makefile; see `docs/PROVIDERS.md` for
operator behavior and protocol boundaries.
