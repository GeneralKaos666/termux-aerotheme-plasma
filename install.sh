#!/bin/bash
CUR_DIR="${PWD}"

BRANCH_VERSION="Plasma/6.7"

INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX:-${PREFIX:-/usr}}"
TERMUX_INSTALL=0

if [[ -n "${PREFIX}" && "${INSTALL_PREFIX}" == "${PREFIX}" ]]; then
    TERMUX_INSTALL=1
fi

run_install_cmd() {
    if [[ -n "${SU_CMD}" ]]; then
        "${SU_CMD}" "$@"
    else
        "$@"
    fi
}

clone_or_update_repo() {
    local repo_url="$1"
    local repo_dir="$2"

    if [[ -d "${repo_dir}/.git" ]]; then
        git -C "${repo_dir}" pull --ff-only || exit 1
    elif [[ -e "${repo_dir}" ]]; then
        echo "Path '${repo_dir}' already exists but is not a git checkout."
        exit 1
    else
        git clone "${repo_url}" "${repo_dir}" || exit 1
    fi
}

if [[ "${TERMUX_INSTALL}" -eq 0 ]]; then
    SU_CMD=sudo
    if [[ -z "$(command -v "${SU_CMD}")" ]]; then
        SU_CMD=doas
        if [[ -z "$(command -v "${SU_CMD}")" ]]; then
            echo "Neither sudo or doas were detected on the system."
            exit 1
        fi
    fi
else
    SU_CMD=
fi

if [[ -z "${LIBEXEC_DIR}" ]]; then
    LIBEXEC_DIR=lib
fi

if [[ -z "${UAC_LIBEXEC_DIR}" ]]; then
    UAC_LIBEXEC_DIR="${LIBEXEC_DIR}"
fi

if [[ "$(command -v dnf)" ]]; then # Automatically change for Fedora
    LIBEXEC_DIR=libexec
    UAC_LIBEXEC_DIR=libexec/kf6
fi

if [[ "${TERMUX_INSTALL}" -eq 1 ]]; then
    # Termux places libexec binaries under lib/libexec/
    if [[ -x "${INSTALL_PREFIX}/libexec/plasma-dbus-run-session-if-needed" ]]; then
        LIBEXEC_DIR=libexec
    elif [[ -x "${INSTALL_PREFIX}/lib/libexec/plasma-dbus-run-session-if-needed" ]]; then
        LIBEXEC_DIR=lib/libexec
    elif [[ -x "${INSTALL_PREFIX}/lib/plasma-dbus-run-session-if-needed" ]]; then
        LIBEXEC_DIR=lib
    fi

    if [[ -x "${INSTALL_PREFIX}/libexec/kf6/polkit-kde-authentication-agent-1" ]]; then
        UAC_LIBEXEC_DIR=libexec/kf6
    elif [[ -x "${INSTALL_PREFIX}/lib/libexec/kf6/polkit-kde-authentication-agent-1" ]]; then
        UAC_LIBEXEC_DIR=lib/libexec/kf6
    elif [[ -x "${INSTALL_PREFIX}/libexec/polkit-kde-authentication-agent-1" ]]; then
        UAC_LIBEXEC_DIR=libexec
    elif [[ -x "${INSTALL_PREFIX}/lib/libexec/polkit-kde-authentication-agent-1" ]]; then
        UAC_LIBEXEC_DIR=lib/libexec
    elif [[ -x "${INSTALL_PREFIX}/lib/polkit-kde-authentication-agent-1" ]]; then
        UAC_LIBEXEC_DIR=lib
    fi
fi

export CMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"
export LIBEXEC_DIR
export UAC_LIBEXEC_DIR

CMAKE_CONFIGURE_ARGS=()

mkdir -p repos
mkdir -p manifest

if [[ "${TERMUX_INSTALL}" -eq 1 ]]; then
    # Termux's GCC has broken OpenMP CXX support; clang works correctly.
    export CC=clang
    export CXX=clang++

    TERMUX_QT_SHIM="${CUR_DIR}/manifest/termux-qt-shim.cmake"
    cat > "${TERMUX_QT_SHIM}" <<'EOF'
# Termux runs natively, but its CMake/Qt report CMAKE_SYSTEM_NAME=Android, which
# sets ANDROID=TRUE and makes Qt take Android build paths (and call undefined
# internal Android macros). Termux does not build Android APKs.
#
# The Aero theme project owns a Termux hack (cmake/TermuxQt6AndroidHack.cmake)
# that it loads while ANDROID is set, so leave its signal intact. Every other
# project (external repos and nested project() calls) gets ANDROID forced off.
if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/TermuxQt6AndroidHack.cmake")
    set(ANDROID OFF)
endif()

if(NOT COMMAND _qt_internal_collect_qml_root_paths)
    function(_qt_internal_collect_qml_root_paths target)
    endfunction()
endif()
if(NOT COMMAND qt6_android_apply_arch_suffix)
    function(qt6_android_apply_arch_suffix target)
    endfunction()
endif()
if(NOT COMMAND _qt_internal_android_resolve_gradle_multi_module)
    function(_qt_internal_android_resolve_gradle_multi_module)
    endfunction()
endif()
if(NOT COMMAND _qt_internal_android_get_target_android_build_dir)
    function(_qt_internal_android_get_target_android_build_dir)
    endfunction()
endif()
EOF
    # CMAKE_PROJECT_INCLUDE (unlike CMAKE_PROJECT_TOP_LEVEL_INCLUDES) runs after
    # every project() call, so ANDROID stays off even after nested project()s.
    CMAKE_CONFIGURE_ARGS+=("-DCMAKE_PROJECT_INCLUDE=${TERMUX_QT_SHIM}")
    CMAKE_CONFIGURE_ARGS+=("-DCMAKE_POSITION_INDEPENDENT_CODE=ON")

    # Termux ships KWin as KWinX11, but several components call
    # find_package(KWin). Install a KWin config shim into a throwaway prefix so
    # that lookup resolves to KWinX11. A prefix is used (rather than
    # CMAKE_MODULE_PATH) because the top-level project overrides
    # CMAKE_MODULE_PATH, while CMAKE_PREFIX_PATH is inherited by every repo.
    TERMUX_KWIN_SHIM_DIR="${CUR_DIR}/manifest/kwin-shim"
    if [[ -f "${INSTALL_PREFIX}/lib/cmake/KWinX11/KWinX11Config.cmake" &&
        ! -f "${INSTALL_PREFIX}/lib/cmake/KWin/KWinConfig.cmake" ]]; then
        mkdir -p "${TERMUX_KWIN_SHIM_DIR}/lib/cmake/KWin"
        cp "${CUR_DIR}/cmake/FindKWin.cmake" "${TERMUX_KWIN_SHIM_DIR}/lib/cmake/KWin/KWinConfig.cmake"
        CMAKE_CONFIGURE_ARGS+=("-DCMAKE_PREFIX_PATH=${TERMUX_KWIN_SHIM_DIR}")
    fi

    # Termux ships the KWin effects DBus interface as
    # kwin_x11_org.kde.kwin.Effects.xml, while atpootb expects the canonical
    # org.kde.kwin.Effects.xml. Provide the expected name when it is missing.
    TERMUX_DBUS_INTERFACES="${INSTALL_PREFIX}/share/dbus-1/interfaces"
    TERMUX_DBUS_SHIM_CREATED=0
    if [[ -f "${TERMUX_DBUS_INTERFACES}/kwin_x11_org.kde.kwin.Effects.xml" &&
        ! -e "${TERMUX_DBUS_INTERFACES}/org.kde.kwin.Effects.xml" ]]; then
        ln -s kwin_x11_org.kde.kwin.Effects.xml "${TERMUX_DBUS_INTERFACES}/org.kde.kwin.Effects.xml"
        TERMUX_DBUS_SHIM_CREATED=1
    fi
fi

cd repos

# libplasma last
clone_or_update_repo https://gitgud.io/aeroshell/libplasma.git libplasma
cd libplasma
cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -B build . || exit 1
cmake --build build || exit 1
run_install_cmd cmake --install build || exit 1
cp build/install_manifest.txt "$CUR_DIR/manifest/libplasma_install_manifest.txt"
cd "$CUR_DIR/repos"

# uac-polkit-agent
#clone_or_update_repo https://gitgud.io/aeroshell/uac-polkit-agent.git uac-polkit-agent
#cd uac-polkit-agent
#cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -DCMAKE_INSTALL_LIBEXECDIR="${UAC_LIBEXEC_DIR}" -B build . || exit 1
#cmake --build build || exit 1
#run_install_cmd cmake --install build || exit 1
#cp build/install_manifest.txt "$CUR_DIR/manifest/uac-polkit-agent_install_manifest.txt"
#cd "$CUR_DIR/repos"

# SMOD
clone_or_update_repo https://gitgud.io/aeroshell/smod.git smod
cd smod
# The default build also builds the Wayland glow effect, which needs the KWin
# Wayland headers. On Termux only the decoration and the X11 effect are built.
SMOD_BUILD_ARGS=()
if [[ "${TERMUX_INSTALL}" -eq 1 && "$*" == *"--skip-wayland"* ]]; then
    SMOD_BUILD_ARGS+=("-DBUILD_EFFECT=OFF")
fi
cmake "${CMAKE_CONFIGURE_ARGS[@]}" "${SMOD_BUILD_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -B build . || exit 1
cmake --build build || exit 1
run_install_cmd cmake --install build || exit 1
cp build/install_manifest.txt "$CUR_DIR/manifest/smod_install_manifest.txt"

if [[ ! "$*" == *"--skip-wayland"* ]]; then
    if [[ -f smodglow/build-wl/install_manifest.txt ]]; then
        cp smodglow/build-wl/install_manifest.txt "$CUR_DIR/manifest/smodglow_install_manifest.txt"
    fi
fi

if [[ ! "$*" == *"--skip-x11"* ]]; then
    cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -DBUILD_DECORATION=OFF -DBUILD_EFFECTX11=ON -B build-x11 . || exit 1
    cmake --build build-x11 || exit 1
    run_install_cmd cmake --install build-x11 || exit 1
    cp build-x11/install_manifest.txt "$CUR_DIR/manifest/smodglow-x11_install_manifest.txt"
fi
cd "$CUR_DIR/repos"

# Aeroshell Workspace
clone_or_update_repo https://gitgud.io/aeroshell/aeroshell-workspace.git aeroshell-workspace
cd aeroshell-workspace
cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -B build . || exit 1
cmake --build build || exit 1
run_install_cmd cmake --install build || exit 1
if command -v update-mime-database >/dev/null 2>&1; then
    run_install_cmd update-mime-database "${INSTALL_PREFIX}/share/mime"
fi
cp build/install_manifest.txt "$CUR_DIR/manifest/aeroshell-workspace_install_manifest.txt"
cd "$CUR_DIR/repos"

if [[ ! "$*" == *"--skip-wayland"* ]]; then
# Aeroshell KWin
clone_or_update_repo https://gitgud.io/aeroshell/aeroshell-kwin-components.git aeroshell-kwin-components
cd aeroshell-kwin-components
cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -DKWIN_BUILD_WAYLAND=ON -B build . || exit 1
cmake --build build || exit 1
run_install_cmd cmake --install build || exit 1
cp build/install_manifest.txt "$CUR_DIR/manifest/aeroshell-kwin-components_install_manifest.txt"
if [[ ! "$*" == *"--skip-x11"* ]]
then
    cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -DKWIN_BUILD_WAYLAND=OFF -DKWIN_INSTALL_MISC=OFF -B build_x11 . || exit 1
    cmake --build build_x11 || exit 1
    run_install_cmd cmake --install build_x11 || exit 1
    cp build_x11/install_manifest.txt "$CUR_DIR/manifest/aeroshell-kwin-components-x11_install_manifest.txt"
fi
cd "$CUR_DIR/repos"
fi

# Aeroshell SDDM KCM
clone_or_update_repo https://gitgud.io/aeroshell/aeroshell-sddm-kcm.git aeroshell-sddm-kcm
cd aeroshell-sddm-kcm
cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -B build . || exit 1
cmake --build build || exit 1
run_install_cmd cmake --install build || exit 1
cp build/install_manifest.txt "$CUR_DIR/manifest/aeroshell-sddm-kcm_install_manifest.txt"
cd "$CUR_DIR/repos"

# Aerothemeplasma icons
clone_or_update_repo https://gitgud.io/aeroshell/atp/aerothemeplasma-icons aerothemeplasma-icons
cd aerothemeplasma-icons
cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -B build . || exit 1
cmake --build build || exit 1
run_install_cmd cmake --install build || exit 1
cp build/install_manifest.txt "$CUR_DIR/manifest/icons_install_manifest.txt"
cd "$CUR_DIR/repos"

# Aerothemeplasma sounds
clone_or_update_repo https://gitgud.io/aeroshell/atp/aerothemeplasma-sounds aerothemeplasma-sounds
cd aerothemeplasma-sounds
cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -B build . || exit 1
cmake --build build || exit 1
run_install_cmd cmake --install build || exit 1
cp build/install_manifest.txt "$CUR_DIR/manifest/sounds_install_manifest.txt"
cd "$CUR_DIR/repos"

# Aerothemeplasma
cd "$CUR_DIR"
cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -DCMAKE_INSTALL_LIBEXECDIR="${LIBEXEC_DIR}" -B build . || exit 1
cmake --build build || exit 1
run_install_cmd cmake --install build || exit 1
cp build/install_manifest.txt "$CUR_DIR/manifest/aerothemeplasma_install_manifest.txt"
if [[ "${TERMUX_DBUS_SHIM_CREATED:-0}" -eq 1 ]]; then
    # Track the compatibility symlink so "make uninstall" removes it too. A
    # leading newline is used because install_manifest.txt has no trailing one.
    printf '\n%s\n' "${TERMUX_DBUS_INTERFACES}/org.kde.kwin.Effects.xml" >>build/install_manifest.txt
    printf '\n%s\n' "${TERMUX_DBUS_INTERFACES}/org.kde.kwin.Effects.xml" >>"$CUR_DIR/manifest/aerothemeplasma_install_manifest.txt"
fi
if [[ ! "$*" == *"--skip-x11"* ]]
then
    cmake "${CMAKE_CONFIGURE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -DCMAKE_INSTALL_LIBEXECDIR="${LIBEXEC_DIR}" -DINSTALL_X11_COMPONENTS=ON -B build_x11 . || exit 1
    cmake --build build_x11 || exit 1
    run_install_cmd cmake --install build_x11 || exit 1
    cp build_x11/install_manifest.txt "$CUR_DIR/manifest/aerothemeplasma-x11_install_manifest.txt"
fi
cd "$CUR_DIR/repos"


echo "Done."
