{
  fetchurl,
  lib,
  makeWrapper,
  patchelf,
  stdenvNoCC,
  bintools,

  # Linked dynamic libraries.
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gcc-unwrapped,
  gdk-pixbuf,
  glib,
  gtk3,
  gtk4,
  libdrm,
  libglvnd,
  libkrb5,
  libX11,
  libxcb,
  libXcomposite,
  libXcursor,
  libXdamage,
  libXext,
  libXfixes,
  libXi,
  libxkbcommon,
  libXrandr,
  libXrender,
  libXScrnSaver,
  libxshmfence,
  libXtst,
  libgbm,
  nspr,
  nss,
  pango,
  pipewire,
  vulkan-loader,
  wayland, # ozone/wayland

  # Command line programs
  coreutils,

  # command line arguments which are always set e.g "--disable-gpu"
  commandLineArgs ? "",

  # Will crash without.
  systemd,

  # Loaded at runtime.
  libexif,
  pciutils,

  # Additional dependencies according to other distros.
  ## Ubuntu
  curl,
  liberation_ttf,
  util-linux,
  wget,
  xdg-utils,
  ## Arch Linux.
  flac,
  harfbuzz,
  icu,
  libopus,
  libpng,
  snappy,
  speechd-minimal,
  ## Gentoo
  bzip2,
  libcap,

  # Fonts (See issue #463615)
  makeFontsConf,
  noto-fonts-cjk-sans,
  noto-fonts-cjk-serif,

  # Necessary for USB audio devices.
  libpulseaudio,
  pulseSupport ? true,

  adwaita-icon-theme,
  gsettings-desktop-schemas,

  # For video acceleration via VA-API (--enable-features=VaapiVideoDecoder)
  libva,
  libvaSupport ? true,

  # For Vulkan support (--enable-features=Vulkan)
  addDriverRunpath,

  # For QT support
  qt6,
}:

let
  pname = "chromium-mv2";
  version = "147.0.7727.55";

  opusWithCustomModes = libopus.override { withCustomModes = true; };

  deps = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    bzip2
    cairo
    coreutils
    cups
    curl
    dbus
    expat
    flac
    fontconfig
    freetype
    gcc-unwrapped.lib
    gdk-pixbuf
    glib
    harfbuzz
    icu
    libcap
    libdrm
    liberation_ttf
    libexif
    libglvnd
    libkrb5
    libpng
    libX11
    libxcb
    libXcomposite
    libXcursor
    libXdamage
    libXext
    libXfixes
    libXi
    libxkbcommon
    libXrandr
    libXrender
    libXScrnSaver
    libxshmfence
    libXtst
    libgbm
    nspr
    nss
    opusWithCustomModes
    pango
    pciutils
    pipewire
    snappy
    speechd-minimal
    systemd
    util-linux
    vulkan-loader
    wayland
    wget
  ]
  ++ lib.optional pulseSupport libpulseaudio
  ++ lib.optional libvaSupport libva
  ++ [
    gtk3
    gtk4
    qt6.qtbase
    qt6.qtwayland
  ];

in
stdenvNoCC.mkDerivation (finalAttrs: {
  inherit pname version;

  src = fetchurl {
    url = "https://github.com/naminx/chromium-mv2/releases/download/v${version}/chromium-browser-stable_147.0.7727.55-1_amd64-147.0.7727.55.deb";
    hash = "sha256-0ZNsCBvIe9lP/xVcNfmJ8qchKJ4RjDrQnwNFW23PqbY=";
  };

  # With strictDeps on, some shebangs were not being patched correctly
  strictDeps = false;

  nativeBuildInputs = [
    makeWrapper
    patchelf
  ];

  buildInputs = [
    # needed for XDG_ICON_DIRS
    adwaita-icon-theme
    glib
    gtk3
    gtk4
    # needed for GSETTINGS_SCHEMAS_PATH
    gsettings-desktop-schemas
  ];

  unpackPhase = ''
    runHook preUnpack
    ${lib.getExe' bintools "ar"} x $src
    tar xf data.tar.xz
    runHook postUnpack
  '';

  rpath = lib.makeLibraryPath deps + ":" + lib.makeSearchPathOutput "lib" "lib64" deps;
  binpath = lib.makeBinPath deps;

  fontsConf = makeFontsConf {
    fontDirectories = [
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
    ];
  };

  installPhase = ''
    runHook preInstall

    appname=chromium
    dist=stable

    exe=$out/bin/chromium-browser-stable

    mkdir -p $out/bin $out/share
    cp -v -a opt/chromium.org/chromium/* $out/share/
    cp -v -a usr/share/* $out/share/

    # replace bundled vulkan-loader
    rm -v $out/share/libvulkan.so.1
    ln -v -s -t "$out/share" "${lib.getLib vulkan-loader}/lib/libvulkan.so.1"

    # Fixup .desktop files
    substituteInPlace $out/share/applications/chromium-browser.desktop \
      --replace-fail /usr/bin/chromium-browser-stable $exe
    substituteInPlace $out/share/applications/org.chromium.Chromium.desktop \
      --replace-fail /usr/bin/chromium-browser-stable $exe

    # Icons
    for icon_file in $out/share/product_logo_[0-9]*.png; do
      num_and_suffix="''${icon_file##*logo_}"
      icon_size="''${num_and_suffix%.*}"
      logo_output_prefix="$out/share/icons/hicolor"
      logo_output_path="$logo_output_prefix/''${icon_size}x''${icon_size}/apps"
      mkdir -p "$logo_output_path"
      mv "$icon_file" "$logo_output_path/chromium-browser.png"
    done

    # "--simulate-outdated-no-au" disables auto updates and browser outdated popup
    makeWrapper "$out/share/chromium-browser" "$exe" \
      --prefix QT_PLUGIN_PATH  : "${qt6.qtbase}/lib/qt-6/plugins" \
      --prefix QT_PLUGIN_PATH  : "${qt6.qtwayland}/lib/qt-6/plugins" \
      --prefix NIXPKGS_QT6_QML_IMPORT_PATH : "${qt6.qtwayland}/lib/qt-6/qml" \
      --prefix LD_LIBRARY_PATH : "$rpath" \
      --prefix PATH            : "$binpath" \
      --suffix PATH            : "${lib.makeBinPath [ xdg-utils ]}" \
      --prefix XDG_DATA_DIRS   : "$XDG_ICON_DIRS:$GSETTINGS_SCHEMAS_PATH:${addDriverRunpath.driverLink}/share" \
      --set FONTCONFIG_FILE "${finalAttrs.fontsConf}" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
      --add-flags "--simulate-outdated-no-au='Tue, 31 Dec 2099 23:59:59 GMT'" \
      --add-flags ${lib.escapeShellArg commandLineArgs}

    # Make sure that libGL and libvulkan are found by ANGLE libGLESv2.so
    for lib in $out/share/lib*GL*; do
      if [ -f "$lib" ] && readelf -h "$lib" >/dev/null 2>&1; then
        patchelf --set-rpath $rpath "$lib"
      fi
    done

    for elf in $out/share/{chrome,chrome-sandbox,chrome_crashpad_handler}; do
      if [ -f "$elf" ] && readelf -h "$elf" >/dev/null 2>&1; then
        patchelf --set-rpath $rpath "$elf"
        patchelf --set-interpreter ${bintools.dynamicLinker} "$elf"
      fi
    done

    runHook postInstall
  '';

  meta = {
    description = "Custom Chromium Build with MV2 Support";
    homepage = "https://www.chromium.org/Home";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
    mainProgram = "chromium-browser-stable";
  };
})
