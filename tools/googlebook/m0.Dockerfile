FROM debian:trixie-slim@sha256:89c1ea91e897f0fe0a3731595330bc45b8bdef4047464a07116f891a94054b31 AS probe
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc libc6-dev libvulkan-dev
COPY vkprobe.c /src/vkprobe.c
RUN gcc -O2 -Wall -o /vkprobe /src/vkprobe.c -lvulkan

FROM debian:trixie-slim@sha256:89c1ea91e897f0fe0a3731595330bc45b8bdef4047464a07116f891a94054b31
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      mesa-vulkan-drivers libvulkan1 vulkan-tools vkmark libglvnd0 libegl1 libgl1 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=probe /vkprobe /usr/local/bin/vkprobe
COPY nvidia/ /opt/nvidia/
RUN set -e; L=/usr/lib/x86_64-linux-gnu; \
    if [ -n "$(ls /opt/nvidia)" ]; then \
      v=$(ls /opt/nvidia/libGLX_nvidia.so.* | sed 's/.*\.so\.//'); \
      cp -a /opt/nvidia/lib* $L/; \
      ln -sf libGLX_nvidia.so.$v $L/libGLX_nvidia.so.0; ln -sf libEGL_nvidia.so.$v $L/libEGL_nvidia.so.0; \
      ln -sf libnvidia-egl-gbm.so.1.1.3 $L/libnvidia-egl-gbm.so.1; \
      mkdir -p /usr/share/vulkan/icd.d /usr/share/vulkan/implicit_layer.d /usr/share/glvnd/egl_vendor.d /usr/share/egl/egl_external_platform.d $L/gbm; \
      cp /opt/nvidia/nvidia_icd.json /usr/share/vulkan/icd.d/; cp /opt/nvidia/nvidia_layers.json /usr/share/vulkan/implicit_layer.d/; \
      cp /opt/nvidia/10_nvidia.json /usr/share/glvnd/egl_vendor.d/; cp /opt/nvidia/15_nvidia_gbm.json /usr/share/egl/egl_external_platform.d/; \
      ln -sf ../libnvidia-allocator.so.$v $L/gbm/nvidia-drm_gbm.so; \
    fi; rm -rf /opt/nvidia; ldconfig
