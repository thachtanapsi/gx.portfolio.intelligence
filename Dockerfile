ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250428-slim

FROM python:3.12-slim-bookworm AS trading_agents

ARG PIP_TIMEOUT_SECONDS=300
ARG PIP_RETRY_COUNT=10

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /opt/trading_agents
RUN python -m venv /opt/trading_agents/.venv
COPY TradingAgents/pyproject.toml TradingAgents/README.md ./
COPY TradingAgents/tradingagents ./tradingagents
COPY TradingAgents/cli ./cli
RUN --mount=type=cache,id=gx-pi-pip,target=/root/.cache/pip,sharing=locked \
    /opt/trading_agents/.venv/bin/pip install \
    --timeout "${PIP_TIMEOUT_SECONDS}" \
    --retries "${PIP_RETRY_COUNT}" \
    ".[gx-postgres,fireant,vn-media,vn-macro]"

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY gx.portfolio.intelligence/mix.exs gx.portfolio.intelligence/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY gx.portfolio.intelligence/config config
COPY gx.portfolio.intelligence/lib lib
COPY gx.portfolio.intelligence/priv priv
COPY gx.portfolio.intelligence/rel rel
RUN chmod +x rel/overlays/bin/server && mix compile && mix release

FROM python:3.12-slim-bookworm AS app
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 libgomp1 openssl libncurses6 locales ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN install -d -m 0750 -o 65534 -g 65534 \
    /data/gx-pi/artifacts /data/gx-pi/artifacts/runtime-home
COPY --from=build /app/_build/prod/rel/gx_portfolio_intelligence ./
COPY --from=trading_agents /opt/trading_agents /opt/trading_agents
USER nobody
ENV HOME=/data/gx-pi/artifacts/runtime-home \
    MIX_ENV=prod \
    PYTHONDONTWRITEBYTECODE=1
CMD ["/app/bin/server"]
