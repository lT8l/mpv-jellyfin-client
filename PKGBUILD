# Maintainer: lT8l

pkgname=mpv-jellyfin-client-git
_pkgname=mpv-jellyfin-client
pkgver=r0
pkgrel=1
pkgdesc='mpv plugin that turns it into a Jellyfin client'
url='https://github.com/lT8l/mpv-jellyfin-client'
arch=('any')
license=('Unlicense')
depends=('mpv' 'curl')
makedepends=('git')
provides=('mpv-jellyfin-client')
conflicts=('mpv-jellyfin-client')
source=("git+$url.git")
sha256sums=('SKIP')

pkgver() {
  cd "$srcdir/$_pkgname"
  git describe --long --tags --always | sed 's/^v//;s/-/.r/;s/-/./'
}

package () {
  cd "$srcdir/$_pkgname"
  install -Dm644 scripts/jellyfin_client.lua -t "$pkgdir/etc/mpv/scripts"
  install -Dm644 script-opts/jellyfin_client.conf -t "$pkgdir/etc/mpv/script-opts"
}
