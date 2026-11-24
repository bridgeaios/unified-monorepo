FROM node:20-alpine

WORKDIR /app

# Copy package files
COPY package*.json ./
COPY turbo.json ./

# Copy all packages
COPY packages ./packages
COPY middleware ./middleware
COPY configs ./configs

# Install dependencies
RUN npm ci --workspaces

# Build all packages
RUN npm run build

# Expose port
EXPOSE 3000

# Start the agent
CMD ["node", "packages/agent-core/index.js"]
