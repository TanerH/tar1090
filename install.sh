#!/bin/bash
set -e

srcdir=/run/dump1090-fa
repo="https://github.com/tanerh/tar1090"
ipath=/usr/local/share/tar1090
lighttpd=no
nginx=no

mkdir -p $ipath

if ! id -u tar1090 &>/dev/null
then
	adduser --system --home $ipath --no-create-home --quiet tar1090
fi

command_package="git git/jq jq/7za p7zip-full/"
packages=""

while read -r -d '/' CMD PKG
do
	if ! command -v "$CMD" &>/dev/null
	then
		echo "command $CMD not found, will try to install package $PKG"
		packages+="$PKG "
	fi
done < <(echo "$command_package")

if [[ -n "$packages" ]]
then
	echo "Installing required packages: $packages"
	apt-get update || true
	if ! apt-get install -y $packages
	then
		echo "Failed to install required packages: $packages"
		echo "Exiting ..."
		exit 1
	fi
	hash -r || true
fi

if [ -d /etc/lighttpd/conf-enabled/ ] && [ -d /etc/lighttpd/conf-available ] && command -v lighttpd &>/dev/null
then
	lighttpd=yes
fi

if command -v nginx &>/dev/null
then
	nginx=yes
fi


if [[ "$1" == "test" ]]
then
	rm -r /tmp/tar1090-test 2>/dev/null || true
	mkdir -p /tmp/tar1090-test
	cp -r ./* /tmp/tar1090-test
	cd /tmp/tar1090-test

elif git clone --depth 1 $repo $ipath/git 2>/dev/null || cd $ipath/git
then
	cd $ipath/git
	git checkout -f master
	git fetch
	git reset --hard origin/master

elif wget --timeout=30 -q -O /tmp/master.zip $repo/archive/master.zip && unzip -q -o master.zip
then
	cd /tmp/tar1090-master
else
	echo "Unable to download files, exiting! (Maybe try again?)"
	exit 1
fi

if [[ -n $1 ]] && [ "$1" != "test" ] ; then
	srcdir=$1
elif ! [[ -d /run/dump1090-fa ]] ; then
	if [[ -d /run/dump1090 ]]; then
		srcdir=/run/dump1090
	elif [[ -d /run/dump1090-mutability ]]; then
		srcdir=/run/dump1090-mutability
	elif [[ -d /run/readsb ]]; then
		srcdir=/run/readsb
	elif [[ -d /run/skyaware978 ]]; then
		srcdir=/run/skyaware978
	fi
fi

if [ -f /etc/default/tar1090_instances ]; then
	instances=$(</etc/default/tar1090_instances)	
else
	instances="$srcdir tar1090"
fi

if ! diff tar1090.sh /usr/local/share/tar1090/tar1090.sh &>/dev/null; then
	changed=yes
	while read -r srcdir instance; do
		if [[ "$instance" != "tar1090" ]]; then
			service="tar1090-$instance"
		else
			service="tar1090"
		fi
		systemctl stop $service 2>/dev/null || true
	done < <(echo "$instances")
	cp tar1090.sh $ipath
fi


# copy over base files
cp default install.sh uninstall.sh 99-tar1090-webroot.conf LICENSE README.md \
	95-tar1090-otherport.conf nginx_webroot.conf $ipath


services=""
names=""
while read -r srcdir instance
do
	if [[ "$instance" != "tar1090" ]]; then
		html_path="$ipath/html-$instance"
		service="tar1090-$instance"
	else
		html_path="$ipath/html"
		service="tar1090"
	fi
	services+="$service "
	names+="$instance "

	# don't overwrite existing configuration
	cp -n default /etc/default/$service
	sed -i -e 's/skyview978/skyaware978/' /etc/default/$service

	sed -i.orig -e "s?SOURCE_DIR?$srcdir?g" -e "s?SERVICE?$service?g" -e "s?INSTANCE?$instance?g" -e "s?HTMLPATH?$html_path?g" 88-tar1090.conf
	sed -i.orig -e "s?SOURCE_DIR?$srcdir?g" -e "s?SERVICE?$service?g" -e "s?INSTANCE?$instance?g" -e "s?HTMLPATH?$html_path?g" nginx.conf
	sed -i.orig -e "s?SOURCE_DIR?$srcdir?g" -e "s?SERVICE?$service?g" tar1090.service

	# keep some stuff around
	if [ -f $html_path/defaults*.js ]; then
		cp $html_path/config.js /tmp/tar1090_config.js 2>/dev/null || true
	fi
	cp $html_path/upintheair.json /tmp/tar1090_upintheair.json 2>/dev/null || true
	cp $html_path/color*.css /tmp/tar1090_colors.css 2>/dev/null || true

	rm -rf $html_path 2>/dev/null || true
	cp -r -T html $html_path

	mv /tmp/tar1090_config.js $html_path/config.js 2>/dev/null || true
	mv /tmp/tar1090_colors.css $html_path/colors.css 2>/dev/null || true
	mv /tmp/tar1090_upintheair.json $html_path/upintheair.json 2>/dev/null || true

	epoch=$(date +%s)
	# bust cache for all css and js files

	dir=$(pwd)
	cd $html_path

	sed -i \
		-e "s/dbloader.js/dbloader_$epoch.js/" \
		-e "s/defaults.js/defaults_$epoch.js/" \
		-e "s/early.js/early_$epoch.js/" \
		-e "s/flags.js/flags_$epoch.js/" \
		-e "s/formatter.js/formatter_$epoch.js/" \
		-e "s/layers.js/layers_$epoch.js/" \
		-e "s/markers.js/markers_$epoch.js/" \
		-e "s/planeObject.js/planeObject_$epoch.js/" \
		-e "s/registrations.js/registrations_$epoch.js/" \
		-e "s/script.js/script_$epoch.js/" \
		-e "s/colors.css/colors_$epoch.css/" \
		-e "s/style.css/style_$epoch.css/" \
		index.html

	mv dbloader.js dbloader_$epoch.js
	mv defaults.js defaults_$epoch.js
	mv early.js early_$epoch.js
	mv flags.js flags_$epoch.js
	mv formatter.js formatter_$epoch.js
	mv layers.js layers_$epoch.js
	mv markers.js markers_$epoch.js
	mv planeObject.js planeObject_$epoch.js
	mv registrations.js registrations_$epoch.js
	mv script.js script_$epoch.js
	mv colors.css colors_$epoch.css
	mv style.css style_$epoch.css

	cd "$dir"

	cp nginx.conf $ipath/nginx-$service.conf

	if [[ $lighttpd == yes ]] && ! diff 88-tar1090.conf /etc/lighttpd/conf-enabled/88-$service.conf &>/dev/null
	then
		changed_lighttpd=yes
		cp 88-tar1090.conf /etc/lighttpd/conf-available/88-$service.conf
		ln -f -s ../conf-available/88-$service.conf /etc/lighttpd/conf-enabled/88-$service.conf
	fi

	if [[ $changed == yes ]] || ! diff tar1090.service /lib/systemd/system/$service.service &>/dev/null
	then
		cp tar1090.service /lib/systemd/system/$service.service
		systemctl enable $service
		echo
		echo "Restarting $service ..."
		systemctl restart $service
	fi

	# restore sed modified configuration files
	mv 88-tar1090.conf.orig 88-tar1090.conf
	mv nginx.conf.orig nginx.conf
	mv tar1090.service.orig tar1090.service
done < <(echo "$instances")


if [[ $changed_lighttpd == yes ]] && systemctl status lighttpd >/dev/null; then
	echo "Restarting lighttpd ..."
	systemctl restart lighttpd
fi

if grep -qs '^server.modules += ( "mod_setenv" )' /etc/lighttpd/conf-available/89-dump1090-fa.conf
then
	while read -r FILE; do
		sed -i -e 's/^server.modules += ( "mod_setenv" )/#server.modules += ( "mod_setenv" )/'  "$FILE"
	done < <(find /etc/lighttpd/conf-available/* | grep -v dump1090-fa)
fi

echo --------------


if [[ $nginx == yes ]]; then
	echo
	echo "To configure nginx for tar1090, please add the following line(s) in the server {} section:"
	echo
	for service in $services; do
		echo "include /usr/local/share/tar1090/nginx-$service.conf;"
	done
fi

echo --------------

if [[ $lighttpd == yes ]]; then
	for name in $names; do
		echo "All done! Webinterface available at http://$(ip route | grep -m1 -o -P 'src \K[0-9,.]*')/$name"
	done
elif [[ $nginx == yes ]]; then
	for name in $names; do
		echo "All done! Webinterface once nginx is configured will be available at http://$(ip route | grep -m1 -o -P 'src \K[0-9,.]*')/$name"
	done
else
	echo "All done! You'll need to configure your webserver yourself, see /usr/local/share/tar1090/nginx-tar1090.conf for a reference nginx configuration"
fi
