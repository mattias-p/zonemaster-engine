# Installation

This document describes prerequisites, installation, post-install sanity
checking for Zonemaster::Engine, and rounds up with a few pointer to interfaces
for Zonemaster::Engine. For an overview of the Zonemaster product, please see
the [main Zonemaster Repository].


## Prerequisites

For details on supported operating system versions and Perl verisons for
Zonemaster::Engine, see the [declaration of prerequisites].


## Installation

This instruction covers the following operating systems:

 * [Installation on CentOS]
 * [Installation on Debian]
 * [Installation on FreeBSD]
 * [Installation on Ubuntu]


### Installation on CentOS

1) *Only* for CentOS 8, enable powertools:

   ```sh
   sudo yum config-manager --set-enabled PowerTools
   ```

2) Install the [EPEL] repository:

   ```sh
   sudo yum --enablerepo=extras install epel-release
   ```

3) Make sure the development environment is installed:

   ```sh
   sudo yum groupinstall "Development Tools"
   ```

4) Install binary packages:

   ```sh
   sudo yum install cpanminus libidn-devel openssl-devel perl-Clone perl-core perl-Devel-CheckLib perl-File-ShareDir perl-File-Slurp perl-IO-Socket-INET6 perl-JSON-PP perl-libintl perl-List-MoreUtils perl-Module-Find perl-Moose perl-Net-IP perl-Pod-Coverage perl-Readonly perl-Test-Differences perl-Test-Exception perl-Test-Fatal perl-Test-Pod perl-Text-CSV perl-YAML
   ```

5) Install packages from CPAN:

   ```sh
   sudo cpanm Email::Valid Locale::Msgfmt Module::Install Module::Install::XSUtil MooseX::Singleton Test::More
   ```

6) Install Zonemaster::LDNS and Zonemaster::Engine for *CentOS 7*:

>   **Note** Since DNSSEC Algorithm 15 is not supported on CentOS 7
   ```sh
   sudo cpanm Zonemaster::LDNS --configure-args="--no-ed25519"
   ```

   ```sh
   sudo cpanm Zonemaster::Engine
   ```


7) Install Zonemaster::LDNS and Zonemaster::Engine for *CentOS 8*:

   ```sh
   sudo cpanm Zonemaster::LDNS Zonemaster::Engine
   ```

### Installation on Debian

1) Upgrade to latest patch level

   ```sh
   sudo apt update && sudo apt upgrade
   ```

2) Install dependencies from binary packages:

   ```sh
   sudo apt install autoconf automake build-essential cpanminus libclone-perl libdevel-checklib-perl libemail-valid-perl libfile-sharedir-perl libfile-slurp-perl libidn11-dev libintl-perl libio-socket-inet6-perl libjson-pp-perl liblist-moreutils-perl liblocale-msgfmt-perl libmodule-find-perl libmodule-install-xsutil-perl libmoose-perl libmoosex-singleton-perl libnet-ip-perl libpod-coverage-perl libreadonly-xs-perl libssl-dev libtest-differences-perl libtest-exception-perl libtest-fatal-perl libtest-pod-perl libtext-csv-perl libtool m4
   ```

3) Install dependencies from CPAN:

   ```sh
   sudo cpanm Module::Install Test::More
   ```

4) Install Zonemaster::LDNS and Zonemaster::Engine.

   * On Debian 10 (Buster):

     ```sh
     sudo cpanm Zonemaster::LDNS Zonemaster::Engine
     ```

   * On Debian 9 (Stretch):

     ```sh
     sudo cpanm Zonemaster::LDNS Zonemaster::Engine --configure-args="--no-ed25519"
     ```

   * On Ubuntu 18.04:

     ```sh
     sudo cpanm Zonemaster::LDNS Zonemaster::Engine
     ```

   * On Ubuntu 16.04:

     ```sh
     sudo cpanm Zonemaster::LDNS Zonemaster::Engine --configure-args="--no-ed25519"
     ```

> Note: Support for DNSSEC algorithm 15 (Ed25519) is not included in neither
> Debian 9 nor Ubuntu 16.04. OpenSSL version 1.1.1 or higher is required.


### Installation on FreeBSD

1) Become root:

   ```sh
   su -l
   ```

2) Update list of package repositories:

   Create the file `/usr/local/etc/pkg/repos/FreeBSD.conf` with the 
   following content, unless it is already updated:

   ```
   FreeBSD: {
   url: "pkg+http://pkg.FreeBSD.org/${ABI}/latest",
   }
   ```

3) Check or activate the package system:

   Run the following command, and accept the installation of the `pkg` package
   if suggested.

   ```
   pkg info -E pkg
   ```

4) Update local package repository:

   ```
   pkg update -f
   ```

5) Install dependencies from binary packages:

   * On all versions of FreeBSD install:

     ```sh
     pkg install devel/gmake libidn p5-App-cpanminus p5-Clone p5-Devel-CheckLib p5-Email-Valid p5-File-ShareDir p5-File-Slurp p5-IO-Socket-INET6 p5-JSON-PP p5-List-MoreUtils p5-Locale-libintl p5-Locale-Msgfmt p5-Module-Find p5-Module-Install p5-Module-Install-XSUtil p5-Moose p5-MooseX-Singleton p5-Net-IP-XS p5-Pod-Coverage p5-Readonly-XS p5-Test-Differences p5-Test-Exception p5-Test-Fatal p5-Test-Pod p5-Text-CSV net-mgmt/p5-Net-IP
     ```

   * On FreeBSD 11.x (11.3 or newer) also install OpenSSL 1.1.1 or newer:

     ```sh
     pkg install security/openssl
     ```

   * On FreeBSD 12.x (12.1 or newer) also install:

     ```sh
     pkg install dns/ldns
     ```

6) Install Zonemaster::LDNS:

   * On FreeBSD 11.x (11.3 or newer):

     ```sh
     cpanm Zonemaster::LDNS
     ```

   * On FreeBSD 12.x (12.1 or newer):

     ```sh
     cpanm --configure-args="--no-internal-ldns" Zonemaster::LDNS
     ```

7) Install Zonemaster::Engine:

   ```sh
   cpanm Zonemaster::Engine
   ```


### Installation on Ubuntu

Use the procedure for [installation on Debian].


## Post-installation sanity check

Make sure Zonemaster::Engine is properly installed.

```sh
time perl -MZonemaster::Engine -E 'say join "\n", Zonemaster::Engine->test_module("BASIC", "zonemaster.net")'
```

The command is expected to take a few seconds and print some results about the delegation of zonemaster.net.


## What to do next

* For a command line interface, follow the [Zonemaster::CLI installation] instruction.
* For a web interface, follow the [Zonemaster::Backend installation] and [Zonemaster::GUI installation] instructions.
* For a [JSON-RPC API], follow the [Zonemaster::Backend installation] instruction.
* For a Perl API, see the [Zonemaster::Engine API] documentation.


[Declaration of prerequisites]: https://github.com/zonemaster/zonemaster#prerequisites
[EPEL]: https://fedoraproject.org/wiki/EPEL
[Installation on CentOS]: #installation-on-centos
[Installation on Debian]: #installation-on-debian
[Installation on FreeBSD]: #installation-on-freebsd
[Installation on Ubuntu]: #installation-on-ubuntu
[JSON-RPC API]: https://github.com/zonemaster/zonemaster-backend/blob/master/docs/API.md
[Main Zonemaster Repository]: https://github.com/zonemaster/zonemaster
[Zonemaster::Backend installation]: https://github.com/zonemaster/zonemaster-backend/blob/master/docs/Installation.md
[Zonemaster::CLI installation]: https://github.com/zonemaster/zonemaster-cli/blob/master/docs/Installation.md
[Zonemaster::Engine API]: http://search.cpan.org/~znmstr/Zonemaster-Engine/lib/Zonemaster/Engine/Overview.pod
[Zonemaster::GUI installation]: https://github.com/zonemaster/zonemaster-gui/blob/master/docs/Installation.md
