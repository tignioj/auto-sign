FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55 AS build
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y gcc-mingw-w64-x86-64 msitools p7zip-full && rm -rf /var/lib/apt/lists/*
COPY iTunes64Setup.exe /inputs/iTunes64Setup.exe
RUN echo '25b28905a81406a5edbf482f7f3ee4831a8641d32d29dceda5d1eb3e8d534c08  /inputs/iTunes64Setup.exe' | sha256sum -c - && \
    mkdir /out /extract && cd /extract && 7z x /inputs/iTunes64Setup.exe iTunes64.msi >/dev/null && \
    msiextract -C /extract/itunes /extract/iTunes64.msi >/dev/null && \
    cp /extract/itunes/iTunes/CoreADI64.dll /out/ && \
    echo 'c83a2b4ae2a6abc6a52330527bb6c4c0c6583048973c39f262648731251995ad  /out/CoreADI64.dll' | sha256sum -c -
COPY coreadi-helper.c /inputs/coreadi-helper.c
RUN x86_64-w64-mingw32-gcc -O2 -static -Wall -Wextra -o /out/coreadi-helper.exe /inputs/coreadi-helper.c -lcrypt32

FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y wine64 python3 python3-aiohttp ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /out /opt/autosign/
COPY server.py test_server.py /opt/autosign/
ENV WINEPREFIX=/opt/autosign/wine WINEDEBUG=-all WINEDLLOVERRIDES=mscoree,mshtml=
RUN /usr/lib/wine/wine64 /opt/autosign/coreadi-helper.exe </dev/null && \
    cd /opt/autosign && python3 -m unittest -v test_server && \
    test -z "$(find '/opt/autosign/wine/drive_c/ProgramData/Apple Computer/iTunes/adi' -type f -print -quit)"
EXPOSE 6969
ENTRYPOINT ["python3", "/opt/autosign/server.py"]
