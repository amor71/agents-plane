# Uses pre-built base image with Node, OpenClaw, himalaya, python3 already cached
# Build base first: docker build -t agents-plane-base -f Dockerfile.base .
FROM agents-plane-base

# Only copy scripts that change (fast layer)
COPY startup-test.sh /startup-test.sh
COPY verify.sh /verify.sh
RUN chmod +x /startup-test.sh /verify.sh

# Run startup with test values (no Secret Manager)
ENV AGENT_NAME=TestAgent \
    OWNER_EMAIL=test@example.com \
    AGENT_MODEL=claude-opus-4-6 \
    PROJECT_ID=test-project \
    ANTHROPIC_KEY=sk-test-fake-key \
    SA_KEY_JSON={}

RUN /startup-test.sh

CMD ["/verify.sh"]
