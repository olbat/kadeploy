Name:           kadeploy
Version:        3.0
Release:        0
Group:          System/Cluster
License:        CeCILL V2
URL:            http://gforge.inria.fr/scm/?group_id=2026
Source0:        %{name}-%{version}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch
Summary:        Package of the Kadeploy deployment tool.

%description
Kadeploy 3 is the next generation of the fast and scalable deployment system
for cluster and grid computing. Kadeploy is the reconfiguration system used 
in Grid5000, allowing the users to deploy their own OS on their reserved nodes.

%package common
Summary:        Common part of the Kadeploy deployment tool.
Requires:       ruby, ruby-mysql
Group:          System/Cluster
%description common
This package provide the common part of the Kadeploy deployment tool.

%package server
Summary:        Server part of the Kadeploy deployment tool.
Requires:       ruby, ruby-mysql, kadeploy-common = %{version}, bittorrent, ctorrent, taktuk >= 3.6
Group:          System/Cluster
%description server
This package provide the server part of the Kadeploy deployment tool.

%package client
Summary:        Client part of the Kadeploy deployment tool.
Requires:       ruby, ruby-mysql, kadeploy-common = %{version}
Group:          System/Cluster
%description client
This package provide the client part of the Kadeploy deployment tool.

%prep
%setup -q

%build

%install
rm -rf $RPM_BUILD_ROOT
make install_all DESTDIR=$RPM_BUILD_ROOT DISTRIB=fedora

%check

%clean
rm -rf $RPM_BUILD_ROOT

%files common
%defattr(-,deploy,deploy,-)
%doc License.txt
/usr/local/kadeploy3
%dir /etc/kadeploy3
/etc/kadeploy3/load_kadeploy_env

%files server
%defattr(-,deploy,deploy,-)
/etc/init.d/kadeploy3d
%config(noreplace) /etc/kadeploy3/clusters
%config(noreplace) /etc/kadeploy3/nodes
%config(noreplace) /etc/kadeploy3/specific_conf_g5kdev-cluster
%config(noreplace) /etc/kadeploy3/partition_file_g5kdev-cluster
%config(noreplace) /etc/kadeploy3/cmd
%config(noreplace) /etc/kadeploy3/conf
/usr/bin/kastafior
/usr/sbin/kadeploy3d
/usr/sbin/karights3
%dir /.keys
/.keys/id_deploy
/.keys/id_deploy.pub

%files client
%defattr(-,deploy,deploy,-)
%config(noreplace) /etc/kadeploy3/client_conf
/usr/bin/kaconsole3
/usr/bin/kanodes3
/usr/bin/kastat3
/usr/bin/kadeploy3
/usr/bin/kaenv3
/usr/bin/kareboot3
