# raspberry-make
# https://github.com/gswly/raspberry-make
# do not edit this file, add additional content in file "config"

# load config from external file (optional)
-include config

# config default values
BUILD_DIR ?= $(PWD)/build
BASE ?= https://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2019-04-09/2019-04-08-raspbian-stretch-lite.zip
SIZE ?= 1G
HNAME ?= my-rpi

blank :=
define NL

$(blank)
endef

define DOCKERFILE_PLAYBOOK
COPY $(D) ./
RUN sudo -u pi ANSIBLE_FORCE_COLOR=true /ansible/lib/ld-musl-x86_64.so.1 \
	--library-path=/ansible/lib:/ansible/usr/lib \
	/ansible/usr/bin/python3.6 /ansible/usr/bin/ansible-playbook -i /ansible/inv.ini playbook.yml
RUN rm -rf ./*
endef

define DOCKERFILE_BUILD
######################################
FROM amd64/alpine:3.9 AS base

RUN apk add --no-cache \
	e2fsprogs \
	e2fsprogs-extra \
	mtools \
	util-linux \
	&& rm -rf /var/cache/apk/*

# download base image, extract root, extract boot
RUN wget -O base.tmp.zip $(BASE) \
	&& unzip base.tmp.zip \
	&& rm base.tmp.zip \
	&& mv *img base.img \
	&& dd if=/base.img of=/root.img bs=512 \
	skip=$$(fdisk -l /base.img | tail -n1 | awk '{print $$2}') \
	&& mkdir /rpi \
	&& debugfs -R "rdump / /rpi/" /root.img \
	&& rm /root.img \
	&& dd if=/base.img of=/boot.img bs=512 \
	skip=$$(fdisk -l /base.img | tail -n2 | head -n1 | awk '{print $$2}') \
	count=$$(fdisk -l /base.img | tail -n2 | head -n1 | awk '{print $$4}') \
	&& mcopy -m -s -i /boot.img ::. /rpi/boot/ \
	&& rm /boot.img \
	&& rm /base.img

# backup files that cannot be edited inside docker
RUN cp /rpi/etc/hosts /rpi/etc/_hosts \
	&& cp /rpi/etc/resolv.conf /rpi/etc/_resolv.conf \
	&& cp /rpi/etc/mtab /rpi/etc/_mtab

######################################
FROM amd64/alpine:3.9 AS ansible

RUN apk add --no-cache \
	ansible \
	&& rm -rf /var/cache/apk/*

######################################
FROM multiarch/alpine:armhf-v3.9 AS qemu

######################################
FROM scratch AS run_playbooks

COPY --from=base /rpi/ /
COPY --from=ansible / /ansible
COPY --from=qemu /usr/bin/qemu-arm-static /usr/bin/qemu-arm-static

# restore sudo permissions (lost due to COPY) and test
RUN chmod 4755 /usr/bin/sudo \
	&& sudo -u pi sh -c 'test $$(id -ru) -eq $$(id -u) && test $$(id -u) -eq 1000' \
	&& sudo -u pi sudo sh -c 'test $$(id -ru) -eq $$(id -u) && test $$(id -u) -eq 0'

# prepare for playbooks
RUN echo 'rpi ansible_connection=local ansible_python_interpreter=/usr/bin/python3' > /ansible/inv.ini
WORKDIR /playbook
RUN chown pi:pi /playbook

# run playbooks
$(foreach D,$(shell ls */playbook.yml | xargs -n1 dirname),$(DOCKERFILE_PLAYBOOK)$(NL))

######################################
FROM amd64/alpine:3.9 AS genimage

RUN apk add --no-cache \
	git \
	autoconf \
	automake \
	make \
	gcc \
	musl-dev \
	pkgconfig \
	confuse-dev \
	&& rm -rf /var/cache/apk/*

RUN git clone -b v10 https://github.com/pengutronix/genimage \
	&& cd /genimage \
	&& ./autogen.sh \
	&& ./configure \
	&& make -j$(nproc) \
	&& make install

######################################
FROM amd64/alpine:3.9 AS finalize

RUN apk add --no-cache \
	confuse \
	e2fsprogs \
	mtools \
	&& rm -rf /var/cache/apk/*

COPY --from=genimage /usr/local/bin/genimage /usr/local/bin/
COPY --from=run_playbooks / /rpi

# cleanup
RUN rm -rf /rpi/playbook /rpi/ansible /rpi/pt /rpi/usr/bin/qemu-arm-static

# restore files that cannot be edited inside docker
RUN rm /rpi/etc/hosts && mv /rpi/etc/_hosts /rpi/etc/hosts \
	&& rm /rpi/etc/resolv.conf && mv /rpi/etc/_resolv.conf /rpi/etc/resolv.conf \
	&& rm /rpi/etc/mtab && mv /rpi/etc/_mtab /rpi/etc/mtab

# set hostname
RUN echo $(HNAME) > /rpi/etc/hostname \
	&& sed -i 's/^127\.0\.1\.1.\+$$/127.0.1.1       $(HNAME)/' /rpi/etc/hosts

# replace uuids with device name
RUN sed -i 's/root=[^ ]\+/root=\/dev\/mmcblk0p2/' /rpi/boot/cmdline.txt \
	&& sed -i 's/^.\+\?\/boot /\/dev\/mmcblk0p1 \/boot /' /rpi/etc/fstab \
	&& sed -i 's/^.\+\?\/ /\/dev\/mmcblk0p2 \/ /' /rpi/etc/fstab

# https://github.com/RPi-Distro/pi-gen/blob/30a1528ae13f993291496ac8e73b5ac0a6f82585/export-image/prerun.sh#L58
RUN echo $$'\\n\\
image boot.img {\\n\\
	vfat {\\n\\
		extraargs = "-n boot -F 32"\\n\\
	}\\n\\
	size = 48M\\n\\
}' > /genimage_boot.cfg

RUN echo $$'\\n\\
image root.img {\\n\\
	ext4 {\\n\\
		use-mke2fs = true\\n\\
		extraargs = "-L rootfs -O ^huge_file -O ^metadata_csum -O ^64bit"\\n\\
	}\\n\\
	size = $(SIZE)\\n\\
}' > /genimage_root.cfg

RUN echo $$'\\n\\
image output.img {\\n\\
	hdimage {\\n\\
	}\\n\\
	partition boot {\\n\\
		partition-type = 0xC\\n\\
		image = boot.img\\n\\
	}\\n\\
	partition root {\\n\\
		partition-type = 0x83\\n\\
		image = root.img\\n\\
	}\\n\\
}' > /genimage_main.cfg

RUN echo $$'#!/bin/sh \\n\\
mv /rpi/boot /rpi_boot \
	&& genimage --config genimage_boot.cfg \
	--rootpath /rpi_boot \
	--inputpath / \
	--outputpath /genimage_out \
	&& genimage --config genimage_root.cfg \
	--rootpath /rpi \
	--inputpath / \
	--outputpath /genimage_out \
	&& genimage --config genimage_main.cfg \
	--inputpath /genimage_out \
	--outputpath / \
	&& rm -rf /genimage_out \\n\\
' > /genimage.sh && chmod +x /genimage.sh
endef

.PHONY: all build export self-update

all: export

# for building we must use docker >= 18.09 and DOCKER_BUILDKIT
# otherwise file owners are erased during COPY
build:
	$(if $(shell which docker),,$(error "docker not found"))
	@test $$(docker version --format '{{.Server.Version}}' | sed 's/^\(.\+\)\.\(.\+\)\.\(.\+\)$$/\1/') -ge 18 \
		|| { echo "docker version must be >= 18.09"; exit 1; }
	@test $$(docker version --format '{{.Server.Version}}' | sed 's/^\(.\+\)\.\(.\+\)\.\(.\+\)$$/\2/') -ge 9 \
		|| { echo "docker version must be >= 18.09"; exit 1; }
	docker run --rm --privileged multiarch/qemu-user-static:register --reset --credential yes >/dev/null
	$(eval export DOCKERFILE_BUILD)
	echo "$$DOCKERFILE_BUILD" | DOCKER_BUILDKIT=1 docker build . -f - \
	-t raspberry-make-build

export: build
	docker run --rm -v $(BUILD_DIR):/o raspberry-make-build \
	sh -c "/genimage.sh && mv /output.img /o/"

MAKEFILE_NAME := $(word $(words $(MAKEFILE_LIST)),$(MAKEFILE_LIST))
self-update:
	curl -o $(MAKEFILE_NAME) https://raw.githubusercontent.com/gswly/raspberry-make/master/rpimake.mk
