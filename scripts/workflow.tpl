#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# Description: Build OpenWrt using GitHub Actions
#

name: ${name}

on:
  repository_dispatch:
  workflow_dispatch:
    inputs:
      ssh:
        description: 'SSH connection to Actions'
        required: false
        default: 'false'

  push:
    paths:
      - '.github/workflows/${workflowName}.yml'
      - '${build}.yml'
    branches:
      - main

  # schedule:
  #   - cron: 0 16 * * *

env:
  REPO_URL: https://github.com/gl-inet/gl-infra-builder
  REPO_BRANCH: main
  UPLOAD_BIN_DIR: true
  UPLOAD_FIRMWARE: true
  UPLOAD_WETRANSFER: true
  UPLOAD_RELEASE: true
  TZ: Asia/Shanghai

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
    - name: Checkout
      uses: actions/checkout@main

    - name: Initialization environment
      env:
        DEBIAN_FRONTEND: noninteractive
      run: |
        sudo rm -rf /etc/apt/sources.list.d/* /usr/share/dotnet /usr/local/lib/android /opt/ghc
        sudo -E apt-get -qq update
        sudo -E apt-get -qq install build-essential libncurses5-dev gawk git libssl-dev gettext zlib1g-dev swig unzip time rsync python3 python3-setuptools python3-yaml -y
        sudo -E apt-get -qq autoremove --purge
        sudo -E apt-get -qq clean
        sudo timedatectl set-timezone "$TZ"
        sudo mkdir -p /workdir
        sudo chown $USER:$GROUPS /workdir

    - name: Clone source code
      working-directory: /workdir
      run: |
        echo $PWD
        echo $GITHUB_WORKSPACE
        git clone $REPO_URL -b $REPO_BRANCH gl-infra-builder
        ln -sf /workdir/gl-infra-builder $GITHUB_WORKSPACE/gl-infra-builder
        cd $GITHUB_WORKSPACE
        [ -e ${build}.yml ] && mv ${build}.yml /workdir/gl-infra-builder/profiles

    - name: run setup.py
      run: |
        cd /workdir/gl-infra-builder
        git config --global user.name "github-actions[bot]"
        git config --global user.email "github-actions[bot]@github.com"
        python3 setup.py -c configs/${config}.yml

    - name: Download package
      id: package
      run: |
        cd /workdir/gl-infra-builder/wlan-ap/openwrt
        ./scripts/gen_config.py ${build} glinet_depends
        git clone https://github.com/gl-inet/glinet4.x.git -b main /workdir/glinet
        ./scripts/feeds update -a
        ./scripts/feeds install -a
        make defconfig
        cd /workdir/gl-infra-builder/wlan-ap/openwrt/files/etc
        echo "$(date +"%Y.%m.%d")" >./glversion

    - name: SSH connection to Actions
      uses: P3TERX/ssh2actions@v1.0.0
      if: (github.event.inputs.ssh == 'true' && github.event.inputs.ssh  != 'false') || contains(github.event.action, 'ssh')
      env:
        TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}

    - name: Compile the firmware
      id: compile
      run: |
        cd /workdir/gl-infra-builder/wlan-ap/openwrt
        echo -e "$(nproc) thread compile"
        make -j$(expr $(nproc) + 1) GL_PKGDIR=/workdir/glinet/ipq60xx/ V=s
        echo "::set-output name=status::success"
        grep '^CONFIG_TARGET.*DEVICE.*=y' .config | sed -r 's/.*DEVICE_(.*)=y/\1/' > DEVICE_NAME
        [ -s DEVICE_NAME ] && echo "DEVICE_NAME=_$(cat DEVICE_NAME)" >> $GITHUB_ENV
        echo "FILE_DATE=_$(date +"%Y%m%d%H%M")" >> $GITHUB_ENV

    - name: Check space usage
      if: (!cancelled())
      run: df -hT

    - name: Upload bin directory
      uses: actions/upload-artifact@main
      if: steps.compile.outputs.status == 'success' && env.UPLOAD_BIN_DIR == 'true'
      with:
        name: OpenWrt_bin${{ env.DEVICE_NAME }}${{ env.FILE_DATE }}
        path: /workdir/gl-infra-builder/wlan-ap/openwrt/bin

    - name: Organize files
      id: organize
      if: env.UPLOAD_FIRMWARE == 'true' && !cancelled() && !failure()
      run: |
        cd /workdir/gl-infra-builder/wlan-ap/openwrt/bin/targets/ipq807x/ipq60xx
        echo $PWD
        rm -rf packages
        echo "FIRMWARE=$PWD" >> $GITHUB_ENV
        echo "::set-output name=status::success"

    - name: Upload firmware directory
      uses: actions/upload-artifact@main
      if: steps.organize.outputs.status == 'success' && !cancelled() && !failure()
      with:
        name: OpenWrt_firmware${{ env.DEVICE_NAME }}${{ env.FILE_DATE }}
        path: ${{ env.FIRMWARE }}

    - name: Upload firmware to WeTransfer
      id: wetransfer
      if: steps.organize.outputs.status == 'success' && env.UPLOAD_WETRANSFER == 'true' && !cancelled() && !failure()
      run: |
        curl -fsSL git.io/file-transfer | sh
        ./transfer wet -s -p 16 --no-progress ${FIRMWARE} 2>&1 | tee wetransfer.log
        echo "::warning file=wetransfer.com::$(cat wetransfer.log | grep https)"
        echo "::set-output name=url::$(cat wetransfer.log | grep https | cut -f3 -d" ")"

    - name: Generate release tag
      id: tag
      if: env.UPLOAD_RELEASE == 'true' && !cancelled() && !failure()
      run: |
        echo "::set-output name=release_tag::${modelUpper}-$(date +"%Y.%m.%d-%H.%M")"
        touch release.txt
        echo "${releaseTitle}" >> release.txt
        [ $UPLOAD_WETRANSFER = true ] && echo "- 🔗 [WeTransfer](${{ steps.wetransfer.outputs.url }})" >> release.txt
        echo -e ${releasePackages} >> release.txt
        echo "::set-output name=status::success"

    - name: Upload firmware to release
      uses: softprops/action-gh-release@v1
      if: steps.tag.outputs.status == 'success' && !cancelled() && !failure()
      env:
        GITHUB_TOKEN: ${{ secrets.AC_GH_TOKEN }}
      with:
        tag_name: ${{ steps.tag.outputs.release_tag }}
        body_path: release.txt
        files: ${{ env.FIRMWARE }}/*

    - name: Delete workflow runs
      uses: GitRML/delete-workflow-runs@main
      with:
        retain_days: 1
        keep_minimum_runs: 3

    - name: Remove old Releases
      uses: dev-drprasad/delete-older-releases@v0.2.0
      if: env.UPLOAD_RELEASE == 'true' && !cancelled() && !failure()
      with:
        keep_latest: ${length}
        delete_tags: true
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
