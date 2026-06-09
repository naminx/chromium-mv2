FROM docker.io/library/ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

# Phase 0: Setup Repositories without GPG Agent dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common gpg wget curl ca-certificates gnupg2 && \
    mkdir -p /etc/apt/keyrings && \
    # 🪄 Fix: Manual Key Injection (Bypassing dirmngr/gpg-agent bug)
    # เราจะดาวน์โหลดกุญแจโดยตรงผ่าน curl แล้วส่งให้ gpg --dearmor เพื่อความชัวร์ค่ะ
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF911AB184317630C59970973E363C90F8F1B6217" \
    | gpg --dearmor -o /etc/apt/keyrings/git-core.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/git-core.gpg] https://ppa.launchpadcontent.net/git-core/ppa/ubuntu jammy main" > /etc/apt/sources.list.d/git-core.list && \
    # Eza Key Injection
    curl -fsSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
    | gpg --dearmor -o /etc/apt/keyrings/gierens.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" > /etc/apt/sources.list.d/gierens.list && \
    # 🪄 Phase 1: Installation (Neovim & Fish PPA usually handle their own keys better via add-apt-repository)
    add-apt-repository ppa:neovim-ppa/unstable -y && \
    add-apt-repository ppa:fish-shell/release-3 -y && \
    apt-get update && apt-get install -y --no-install-recommends \
    git python3 python-is-python3 python3-httplib2 \
    tzdata fuse libfuse2 ciopfs unzip p7zip-full pkg-config \
    binutils rpm dpkg-dev patch gperf git-restore-mtime \
    fakeroot moreutils less gh jq file \
    devscripts lsb-release wget sudo ca-certificates \
    fish neovim ripgrep fzf eza fd-find bat && \
    # Symlinks & Shell Tools
    ln -s /usr/bin/fdfind /usr/local/bin/fd && \
    ln -s /usr/bin/batcat /usr/local/bin/bat && \
    curl -sS https://starship.rs/install.sh | sh -s -- -y && \
    rm -rf /var/lib/apt/lists/*

# Set Timezone
ENV TZ=Asia/Bangkok
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Non-root builder user for FUSE-based builds
RUN useradd -m builder

# Install depot_tools globally
RUN git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git /depot_tools
ENV PATH="/depot_tools:$PATH"
ENV DEPOT_TOOLS_UPDATE=1
# Bootstrap depot_tools (pre-download python3, etc.)
RUN gclient --version
RUN chown -R 1000:100 /depot_tools
ENV DEPOT_TOOLS_UPDATE=0
ENV DEPOT_TOOLS_METRICS=0

WORKDIR /chromium
