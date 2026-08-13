# Build:
#   docker build -t ace-currency-api .
# Run:
#   docker run -p 127.0.0.1:7800:7800 ace-currency-api
#
# Requires runtime/ace-developer.tar.gz to be present at build time -- see
# README.md for how to obtain it. Not committed to the repo (licensed binary).

FROM registry.access.redhat.com/ubi9/ubi-minimal AS builder
RUN microdnf update -y && microdnf install -y util-linux tar findutils && microdnf clean all

WORKDIR /opt/ibm
COPY runtime/ace-developer.tar.gz /tmp/ace-developer.tar.gz
RUN mkdir -p /opt/ibm/ace \
    && tar -xzf /tmp/ace-developer.tar.gz --strip-components 1 --directory /opt/ibm/ace \
    && rm /tmp/ace-developer.tar.gz

FROM registry.access.redhat.com/ubi9/ubi-minimal
RUN microdnf update -y && microdnf install -y findutils util-linux which tar unzip ca-certificates curl \
    && microdnf reinstall -y tzdata && microdnf clean all

# Install ACE for Developers and accept its license non-interactively.
COPY --from=builder /opt/ibm/ace /opt/ibm/ace
RUN /opt/ibm/ace/ace make registry global accept license silently \
    && useradd --uid 1001 --create-home --home-dir /home/aceuser --shell /bin/bash -G mqbrkrs aceuser \
    && chmod -R 777 /home/aceuser /var/mqsi \
    && su - aceuser -c "export LICENSE=accept && . /opt/ibm/ace/server/bin/mqsiprofile && mqsicreateworkdir /home/aceuser/ace-server" \
    && echo ". /opt/ibm/ace/server/bin/mqsiprofile" >> /home/aceuser/.bashrc

# Log4j support for ESQL flows via the third-party "IAM3" Log4jLoggingNode
# SupportPac (github.com/ot4i/node-for-log4j) -- ACE's own Java compute
# nodes can't reach it, so this is the documented way to get real Log4j2
# logging out of an ESQL-only flow. Public, freely downloadable, no
# license gate (unlike the ACE runtime itself). Verified live against this
# exact ACE version/image before wiring it in here: the LIL loader needs
# the raw .par file sitting in a lilPath directory (not its extracted
# contents -- that produces a different, misleading set of non-fatal
# classloading warnings for log4j-core's own optional multi-release-jar
# internals, e.g. async logging via LMAX Disruptor, that this app doesn't
# use anyway).
ARG LOG4J_NODE_VERSION=2.1.2
RUN mkdir -p /home/aceuser/log4j-lil /tmp/iam3 \
    && curl -fsSL -o /tmp/iam3/iam3.zip \
       "https://github.com/ot4i/node-for-log4j/releases/download/v${LOG4J_NODE_VERSION}/iam3.zip" \
    && unzip -o /tmp/iam3/iam3.zip -d /tmp/iam3 \
    && cp "/tmp/iam3/Log4jLoggingNode_v${LOG4J_NODE_VERSION}.par" /home/aceuser/log4j-lil/ \
    && rm -rf /tmp/iam3 \
    && printf 'lilPath: /home/aceuser/log4j-lil\n' > /home/aceuser/ace-server/overrides/server.conf.yaml \
    && chown -R aceuser:aceuser /home/aceuser/log4j-lil /home/aceuser/ace-server/overrides

COPY log4j2-access.xml /home/aceuser/ace-server/log4j2-access.xml
RUN mkdir -p /home/aceuser/ace-server/logs \
    && chown -R aceuser:aceuser /home/aceuser/ace-server/log4j2-access.xml /home/aceuser/ace-server/logs

# Package the flow into a BAR and drop it in the work directory's run/ folder,
# which ACE auto-deploys on startup.
COPY CurrencyApiApp /tmp/CurrencyApiApp
RUN mkdir -p /home/aceuser/ace-server/run \
    && chown -R aceuser:aceuser /tmp/CurrencyApiApp /home/aceuser/ace-server/run \
    && su - aceuser -c "ibmint package --input-path /tmp/CurrencyApiApp --output-bar-file /home/aceuser/ace-server/run/CurrencyApi.bar"

USER 1001
EXPOSE 7600 7800 7843
ENV ACE_SERVER_NAME=ace-server
ENTRYPOINT ["bash", "-c", ". /opt/ibm/ace/server/bin/mqsiprofile && IntegrationServer --name ${ACE_SERVER_NAME} -w /home/aceuser/ace-server"]
