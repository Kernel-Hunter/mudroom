// Copy of images/agent-base/Containerfile, embedded so an installed `mudroom`
// binary can build the image without the repo. A test checks they match.

public enum AgentBaseImage {
    public static let tag = "mudroom/agent-base:latest"

    public static let containerfile = #"""
# Mudroom agent base image: Node LTS plus coding-agent CLIs (Claude Code,
# Codex, Gemini CLI, opencode, Aider).
# Build with `mudroom image build` (tags it mudroom/agent-base:latest).
FROM docker.io/library/node:lts-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ripgrep ca-certificates less procps \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli opencode-ai \
 && npm cache clean --force

# Aider, in its own Python environment managed by uv (no Python from apt).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin
RUN uv tool install --python 3.12 aider-chat \
 && uv cache clean \
 && find /opt/uv -name '__pycache__' -prune -exec rm -rf {} +

# The node user (uid 1000) owns files it creates in /workspace; the host sees
# them as your user. Claude Code also refuses to skip permissions as root.
USER node
ENV HOME=/home/node
WORKDIR /workspace
CMD ["bash"]

"""#
}
