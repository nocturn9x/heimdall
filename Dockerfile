FROM nimlang/nim:2.2.0-ubuntu-regular

RUN apt update && apt-get -y install git clang llvm lld


WORKDIR /app

COPY . /app/

# Force cache to be thrown away when new commits are pushed
ADD https://api.github.com/repos/nocturn9x/heimdall/git/refs/heads/master /.git-hashref


RUN git clone https://github.com/nocturn9x/heimdall --depth 1 && \
    cd heimdall && make native


CMD ["heimdall/bin/heimdall"]
