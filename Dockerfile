# Stage 1: build the Go binary
FROM golang:1.22-alpine AS builder
WORKDIR /build
COPY go/ .
RUN go build -o task_bin .

# Stage 2: runtime with Neovim and ripgrep
FROM alpine:edge

# Install neovim and ripgrep
RUN apk add --no-cache neovim ripgrep git

# Copy plugin source
COPY lua/ /plugin/lua/
COPY plugin/ /plugin/plugin/
COPY syntax/ /plugin/syntax/
COPY ftdetect/ /plugin/ftdetect/
COPY doc/ /plugin/doc/
COPY tests/e2e/ /plugin/tests/e2e/

# Copy built Go binary
COPY --from=builder /build/task_bin /plugin/go/task_bin

# Clone plenary.nvim (needed by test infra)
RUN git clone --depth 1 https://github.com/nvim-lua/plenary.nvim /deps/plenary.nvim

# Create sample notes directory with test data
RUN mkdir -p /root/Documents/Notes
COPY tests/e2e/sample_notes/ /root/Documents/Notes/

# Create state directory
RUN mkdir -p /root/.local/state/task

ENTRYPOINT ["nvim", "--headless", "-u", "/plugin/tests/e2e/smoke_test.lua"]
