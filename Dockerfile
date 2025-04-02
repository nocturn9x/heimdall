# By @agethereal. Thanks Andy!
FROM ubuntu:24.04

# Set non-interactive mode to avoid prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && \
    apt-get install -y curl git clang llvm lld build-essential libssl-dev wget && \
    rm -rf /var/lib/apt/lists/*

# Install Nim using the official installer
RUN curl https://nim-lang.org/choosenim/init.sh -sSf | sh -s -- -y && \
    ln -s ~/.nimble/bin/nim /usr/local/bin/nim && \
    ln -s ~/.nimble/bin/nimble /usr/local/bin/nimble

# Install Git-LFS
RUN wget https://github.com/git-lfs/git-lfs/releases/download/v3.4.0/git-lfs-linux-amd64-v3.4.0.tar.gz && \
    tar -xvf git-lfs-linux-amd64-v3.4.0.tar.gz && \
    cd git-lfs-3.4.0 && \
    ./install.sh && \
    git lfs install

# ------------------------------------------------------------------------------

# Force the cache to break if there have been new commits
ADD https://api.github.com/repos/nocturn9x/heimdall/git/refs/heads/master /.git-hashref

# ------------------------------------------------------------------------------

RUN git clone https://git.nocturn9x.space/heimdall-engine/heimdall --depth 1 && \
    cd heimdall && \
    make native


