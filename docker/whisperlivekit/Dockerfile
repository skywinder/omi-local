FROM ghcr.io/quentinfuxa/whisperlivekit:v0.2.26@sha256:545beb187cf1ef6b0f67c323db3f0e3bd5ab1627c38de02563fab8f35d28f30b

COPY omi_live.py /tmp/omi_live.py
RUN python /tmp/omi_live.py && rm /tmp/omi_live.py
