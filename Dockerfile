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
RUN microdnf update -y && microdnf install -y findutils util-linux which tar \
    && microdnf reinstall -y tzdata && microdnf clean all

# Install ACE for Developers and accept its license non-interactively.
COPY --from=builder /opt/ibm/ace /opt/ibm/ace
RUN /opt/ibm/ace/ace make registry global accept license silently \
    && useradd --uid 1001 --create-home --home-dir /home/aceuser --shell /bin/bash -G mqbrkrs aceuser \
    && chmod -R 777 /home/aceuser /var/mqsi \
    && su - aceuser -c "export LICENSE=accept && . /opt/ibm/ace/server/bin/mqsiprofile && mqsicreateworkdir /home/aceuser/ace-server" \
    && echo ". /opt/ibm/ace/server/bin/mqsiprofile" >> /home/aceuser/.bashrc

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
