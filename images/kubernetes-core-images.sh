#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Description: The script updates kubernetes core image versions and syncs newer images to alibaba cloud container registry.
# Copyright (c) 2026 honeok <i@honeok.com>

set -eEuo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

CORE_IMAGES_FILE="./kubernetes-core-images.md"
: "${ALIYUN_REGISTRY:?missing ALIYUN_REGISTRY}"
: "${ALIYUN_NAMESPACE:?missing ALIYUN_NAMESPACE}"

die() {
    printf '[%s] %s\n' "$(date '+%F %T')" "[ERROR] $*"
    exit 1
}

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "[INFO] $*"
}

## functions library
get_img_ver() {
    local img regex mode

    img="$1"
    mode="$2"

    case "$img" in
    *pause)
        regex='^[0-9]+(\.[0-9]+){1,2}$'
        ;;
    *kube-apiserver | *kube-controller-manager | *kube-scheduler | *kube-proxy | *coredns)
        regex='^v[0-9]+(\.[0-9]+){2}$'
        ;;
    *etcd)
        regex='^[0-9]+(\.[0-9]+){2}-[0-9]+$'
        ;;
    esac

    case "$mode" in
    latest)
        skopeo list-tags "docker://$img" | jq -r '.Tags[]?' | grep -E -- "$regex" | sort -V | tail -n 1
        ;;
    current)
        awk -F: -v img="$img" '$1 == img { print $2; exit }' "$CORE_IMAGES_FILE" | grep -E -- "$regex"
        ;;
    *)
        die "invalid mode: $mode"
        ;;
    esac
}

ver_gt() {
    local l="$1" c="$2"

    [[ "$l" != "$c" && "$(printf '%s\n' "$l" "$c" | sort -V | tail -n 1)" == "$l" ]]
}

update_and_edit() {
    local img="$1" ver="$2"

    sed -Ei "s#^($(printf '%s\n' "$img" | sed 's#[][(){}.^$*+?|/\\]#\\&#g')):[^[:space:]]+\$#\1:${ver}#" "$CORE_IMAGES_FILE"
    # Pass environment variables to github to trigger automatic commits.
    echo "bump_version=1" >> "$GITHUB_OUTPUT"
}

sync_img() {
    local img="$1" tag="$2"
    local dst

    dst="$ALIYUN_REGISTRY/$ALIYUN_NAMESPACE/${img##*/}:$tag"
    docker buildx imagetools inspect "$dst" > /dev/null 2>&1 && log "$dst already exists, skip." && return
    docker pull "$img:$tag"
    docker tag "$img:$tag" "$dst"
    docker push "$dst"
    docker rmi --force "$img:$tag" "$dst"
}

## Main logic.
KUBERNETES_CORE_IMAGES=(
    "registry.k8s.io/pause"
    "registry.k8s.io/kube-apiserver"
    "registry.k8s.io/kube-controller-manager"
    "registry.k8s.io/kube-scheduler"
    "registry.k8s.io/kube-proxy"
    "registry.k8s.io/etcd"
    "registry.k8s.io/coredns/coredns"
)

# docker login "$ALIYUN_REGISTRY" -u "$ALIYUN_USERNAME" --password-stdin <<< "$ALIYUN_PASSWORD" 2> /dev/null

for i in "${KUBERNETES_CORE_IMAGES[@]}"; do
    latest_ver="$(get_img_ver "$i" latest)"
    current_ver="$(get_img_ver "$i" current)"
    ver_gt "$latest_ver" "$current_ver" || continue
    log "$i update: $current_ver -> $latest_ver"
    update_and_edit "$i" "$latest_ver"
    sync_img "$i" "$latest_ver"
done
