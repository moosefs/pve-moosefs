VERSION=0.1.6
PACKAGE=libpve-storage-custom-moosefs-perl
PKGREL=1

DESTDIR=
PREFIX=/usr
SBINDIR=${PREFIX}/sbin
DOCDIR=${PREFIX}/share/doc/${PACKAGE}
DATADIR=${PREFIX}/share/${PACKAGE}

export PERLDIR=${PREFIX}/share/perl5

SOURCES=MooseFSPlugin.pm

ARCH=all
GITVERSION:=$(shell cat .git/refs/heads/main)

DEB=${PACKAGE}_${VERSION}-${PKGREL}_${ARCH}.deb

all: ${DEB}

.PHONY: dinstall
dinstall: deb
	dpkg -i ${DEB}

.PHONY: install
install:
	install -d ${DESTDIR}${PERLDIR}/PVE/Storage/Custom
	for i in ${SOURCES}; do install -D -m 0644 $$i ${DESTDIR}${PERLDIR}/PVE/Storage/Custom/$$i; done
	# Install the patch file
	install -d ${DESTDIR}${DATADIR}
	install -m 0644 pve-moosefs.patch ${DESTDIR}${DATADIR}/

.PHONY: deb ${DEB}
deb ${DEB}:
	rm -rf debian
	mkdir debian
	make DESTDIR=${CURDIR}/debian install
	install -d -m 0755 debian/DEBIAN
	sed -e s/@@VERSION@@/${VERSION}/ -e s/@@PKGRELEASE@@/${PKGREL}/ -e s/@@ARCH@@/${ARCH}/ <control.in >debian/DEBIAN/control
	install -D -m 0644 copyright debian/${DOCDIR}/copyright
	install -m 0644 changelog.Debian debian/${DOCDIR}/
	install -m 0644 triggers debian/DEBIAN/
	install -m 0755 postinst debian/DEBIAN/
	install -m 0755 prerm debian/DEBIAN/
	gzip -9 debian/${DOCDIR}/changelog.Debian
	dpkg-deb --build debian
	mv debian.deb ${DEB}
	rm -rf debian
	lintian ${DEB}

.PHONY: clean
clean:
	rm -rf debian *.deb ${PACKAGE}-*.tar.gz dist *.1 *.tmp
	find . -name '*~' -exec rm {} ';'

.PHONY: distclean
distclean: clean
