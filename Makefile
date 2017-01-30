# Running pip below without pointing to the postgres bin path will fail.
PGSQL_BINPATH="$(shell dirname $$(locate -r 'pg_config$$' | sort | tail -1))"
PATH_EXPORT=export PATH=$$PATH:${PGSQL_BINPATH}:/usr/local/bin;

PYTHON3_PATH=$(shell which python3)

# The proxy info for you site
PROXY=
HTTP_PROXY=
ifneq "${PROXY}" ""
	export http_proxy="http://${PROXY}"
	export https_proxy="http://${PROXY}"
endif

DESTDIR=/var/pcapdb
DD=/bin/dd
# This is used to create a password, not a password hash. As such, it's ok to use
# SHA rather a suitable password hasher like crypt.
HASHER=/usr/bin/sha512sum
SHRED=/usr/bin/shred

RSYSLOGD=/etc/rsyslog.d
NGINX=/etc/nginx
LOGROTATED=/etc/logrotate.d
SUDOERSD=/etc/sudoers.d

# If syslog writes as a special user (rather than root), set that here.
SYSLOG_USER=syslog

ifeq "${DESTDIR}" "$(shell pwd)"
  CAPTURE_USER="$(shell whoami)"
  CAPTURE_GROUP=users
  INSTALL_PERMS=
else
  CAPTURE_USER="capture"
  CAPTURE_GROUP="capture"
  INSTALL_PERMS=--owner=${CAPTURE_USER} --group=${CAPTURE_GROUP} 
endif

# Build and install the capture system.
install-common: setup_dirs ${DESTDIR}/bin/python ${DESTDIR}/lib/packages_installed indexer_install core

install-capture-node: install-common capture-node-configs common-configs
install-search-head: install-common search-head-configs common-configs
install-monolithic: install-common capture-node-configs search-head-configs common-configs

# Create the python ${DESTDIR}/bin/python that will run all our python code
${DESTDIR}/bin/python:
	updatedb
	${PATH_EXPORT} env virtualenv -p ${PYTHON3_PATH} ${DESTDIR}

SYSTEM_DIRS=${DESTDIR}/capture ${DESTDIR}/capture/index ${DESTDIR}/log ${DESTDIR}/static ${DESTDIR}/etc ${DESTDIR}/media

# Setup all the directories needed for the system to run.
setup_dirs: setup_user
ifneq "${DESTDIR}" "$(shell pwd)"
	mkdir -p ${DESTDIR}
	chown ${CAPTURE_USER}:${CAPTURE_GROUP} ${DESTDIR}
endif
	mkdir -p ${SYSTEM_DIRS}
	# Make sure all the directories are owned by the capture user/group.
	chown ${CAPTURE_USER}:${CAPTURE_GROUP} ${SYSTEM_DIRS}
	# The log directory needs to have any files created in it have the CAPTURE_USER as the owner.
	# (That's what SETUID does for directories)
	chmod u+s ${DESTDIR}/log
	# If we have a syslog user, then set the log directory to that as the group, and make
	# the directory group writable.
	if id ${SYSLOG_USER}; then \
		chgrp ${SYSLOG_USER} ${DESTDIR}/log\
		chown g+w ${DESTDIR} \
	fi

core: setup_dirs 
ifneq "${DESTDIR}" "$(shell pwd)"
	cp -R core ${DESTDIR}
	rm -f ${DESTDIR}/core/settings/settings.py
	chown ${CAPTURE_USER}:${CAPTURE_GROUP} -R ${DESTDIR}/core
	-ln -s ${DESTDIR}/core/settings/prod.py ${DESTDIR}/core/settings/settings.py
else
	-ln -s ${DESTDIR}/core/settings/devel.py ${DESTDIR}/core/settings/settings.py
endif
	if [ ! -e ${DESTDIR}/etc/pcapdb.cfg ]; then install -b ${INSTALL_PERMS} etc/pcapdb.cfg.example ${DESTDIR}/etc/pcapdb.cfg; fi

SUPERVISORD_CONF=$(shell find /etc -name supervisord.conf)
common-configs: ${DESTDIR}/etc/syslog.conf ${DESTDIR}/etc/logrotate.conf ${DESTDIR}/etc/sudoers ${DESTDIR}/etc/supervisord_common.conf
	if [ ! -e ${RSYSLOGD} ]; then ln -s ${DESTDIR}/etc/syslog.conf ${RSYSLOGD}/pcapdb.conf; fi
	service rsyslog restart
	if [ ! -e ${LOGROTATED} ]; then ln -s ${DESTDIR}/etc/logrotate.conf ${LOGROTATED}/pcapdb; fi
	install -g root -o root -m 0440 ${DESTDIR}/etc/sudoers /etc/sudoers.d/pcapdb
	# Tell supervisord to include our supervisord conf
	if ! grep -E "^files = ${DESTDIR}/etc/supervisord\*.conf" ${SUPERVISORD_CONF}; then \
		echo "[include]"                                >> ${SUPERVISORD_CONF}; \
		echo "files = ${DESTDIR}/etc/supervisord*.conf"	>> ${SUPERVISORD_CONF}; \
	fi
	service supervisor restart

search-head-configs: ${DESTDIR}/etc/nginx.conf ${DESTDIR}/etc/supervisord_sh.conf ${DESTDIR}/etc/uwsgi.ini
	if [ ! -e /etc/ssl/${HOSTNAME}.pem ]; then \
		echo "\033[31mNo SSL certificate found. Generating a self-signed cert now.";\
		echo "You should replace this with a properly signed cert.\033[0m";\
		openssl req -x509 -newkey rsa:4096 -keyout /etc/ssl/${HOSTNAME}.key -out /etc/ssl/${HOSTNAME}.pem -days 365 -nodes;\
	fi
	if [ -e ${NGINX}/sites-enabled/default ]; then rm ${NGINX}/sites-enabled/default; fi
	if [ ! -e ${NGINX}/conf.d/pcapdb.conf ]; then ln -s ${DESTDIR}/etc/nginx.conf ${NGINX}/conf.d/pcapdb.conf; fi
	service nginx reload

capture-node-configs: ${DESTDIR}/etc/supervisord_cn.conf


# We just make this file in place, since it depends more on the make 
# variables than anything else.
${DESTDIR}/etc/syslog.conf:
	echo "# Pcapdb logs to local5 at all levels" > $@
	echo "local5.*	${DESTDIR}/etc/syslog.conf" >> $@

# Escape the forward slashes in the DESTDIR, so we can use it in a sed script
DESTDIR_ESCAPED=$(shell echo ${DESTDIR} | sed 's/\//\\\//g')
HOSTNAME=$(shell hostname -f)
${DESTDIR}/etc/nginx.conf: etc/nginx.conf.tmpl
	sed 's/DESTDIR/${DESTDIR_ESCAPED}/g;s/HOSTNAME/${HOSTNAME}/g' etc/nginx.conf.tmpl > $@

.PHONY: ${DESTDIR}/etc/logrotate.conf
${DESTDIR}/etc/logrotate.conf:
	echo "${DESTDIR}/log/*.log {" > $@
	echo "  daily"		>> $@
	echo "  missingok"	>> $@
	echo "  compress"	>> $@
	echo "  rotate 7"	>> $@
	echo "}"			>> $@

# Most of the commands that need to be run as root are wrapped in shell
# scripts to severely limit their arguments. 
.PHONY: ${DESTDIR}/etc/sudoers
${DESTDIR}/etc/sudoers: 
	echo "capture	ALL=NOPASSWD:${DESTDIR}/core/bin/sudo/*"		>  $@
	echo "# Note that the * in the arguments below is usually "		>> $@ 
	echo "# dangerous. We're relying on the fact that readlink "	>> $@
	echo "# takes only a single filename argument."					>> $@
	echo "capture	ALL=NOPASSWD:/bin/readlink -f /proc/[0-9]*/exe" >> $@
	echo "capture	ALL=NOPASSWD:/bin/umount"						>> $@
	echo "capture	ALL=NOPASSWD:/sbin/blkid"						>> $@

${DESTDIR}/etc/supervisord_common.conf: etc/supervisord_common.conf.tmpl
	sed 's/DESTDIR/${DESTDIR_ESCAPED}/g' etc/supervisord_common.conf.tmpl > $@	

WWW_USER=$(shell for user in nginx www-data; do if id $$user > /dev/null; then echo $$user; fi; done)
${DESTDIR}/etc/supervisord_sh.conf: etc/supervisord_sh.conf.tmpl
	sed 's/DESTDIR/${DESTDIR_ESCAPED}/g;s/WWW_USER/${WWW_USER}/g' etc/supervisord_sh.conf.tmpl > $@	

${DESTDIR}/etc/supervisord_cn.conf: etc/supervisord_cn.conf.tmpl
	sed 's/DESTDIR/${DESTDIR_ESCAPED}/g' etc/supervisord_cn.conf.tmpl > $@	

${DESTDIR}/etc/uwsgi.ini: etc/uwsgi.ini.tmpl
	sed 's/DESTDIR/${DESTDIR_ESCAPED}/g' etc/uwsgi.ini.tmpl > $@	

ifeq "${DESTDIR}" "$(shell pwd)"
setup_user:
	# Do nothing when installing in place.
else
setup_user:
	# Create the capture user and group
	groupadd -f -r ${CAPTURE_GROUP}
	if ! id ${CAPTURE_USER} > /dev/null; then useradd -d ${DESTDIR} -c "PcapDB User" -g ${CAPTURE_GROUP} -M -r ${CAPTURE_USER}; fi
endif 

${DESTDIR}/lib/packages_installed: ${DESTDIR}/bin/python requirements.txt
	http_proxy=${http_proxy} export https_proxy=${http_proxy} ${PATH_EXPORT} ${DESTDIR}/bin/pip install -r requirements.txt 
	echo "Warning: if you have multiple postgres versions installed and/or psycopg2 fails to work,"
	echo "then it's possibly because the wrong postgres bin path was used."
	echo "Use pip to uninstall psycopg2, and reinstall with the correct path."
	touch ${DESTDIR}/lib/packages_installed

indexer:
	make -C indexer

indexer_install: setup_dirs
	make -C indexer install DESTDIR=${DESTDIR}

