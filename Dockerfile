# ──────────────────────────────────────────────────────────────
#  PPREV Protocol — Docker Simulation Environment
# ──────────────────────────────────────────────────────────────
#  Builds a minimal Node.js image with Hardhat, compiles the
#  contract, and runs the full-flow simulation by default.
# ──────────────────────────────────────────────────────────────

FROM node:20-slim

WORKDIR /app

# Install deps first (layer caching)
COPY package.json ./
RUN npm install --prefer-offline --no-audit --no-fund

# Copy project files
COPY hardhat.config.ts tsconfig.json ./
COPY src/ ./src/
COPY test/ ./test/
COPY test-hardhat/ ./test-hardhat/
COPY scripts/ ./scripts/

# Compile contracts
RUN npx hardhat compile

# Default: run the full simulation
CMD ["npx", "hardhat", "run", "scripts/simulate.ts"]
