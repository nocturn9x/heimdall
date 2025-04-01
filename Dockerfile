FROM nimlang/nim:2.2.0-ubuntu-regular

RUN apt update && apt-get -y install git clang llvm lld git-lfs


WORKDIR /app

COPY . /app/

# Force cache to be thrown away when new commits are pushed
ADD https://api.github.com/repos/nocturn9x/heimdall/git/refs/heads/master /.git-hashref


# The LFS repo is only on my personal gitea. The above cache thing still works because
# GitHub is used as a mirror for the main repo
RUN git clone https://git.nocturn9x.space/heimdall-engine/heimdall --depth 1 && \
    cd heimdall && make native


CMD ["heimdall/bin/heimdall"]
