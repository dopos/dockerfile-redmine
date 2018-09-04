FROM ruby:2.4-slim-stretch
MAINTAINER zan@whiteants.net

# When using previous version (5.1.12), the Passenger write to the log about a strongly
# recomendation to upgrade the version to 5.3.3 which includes important security updates
ENV PASSENGER_VERSION=5.3.3

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r redmine && useradd -r -g redmine -m -d /home/redmine redmine

RUN apt-get update && apt-get install -y --no-install-recommends \
	apt-utils \
	ca-certificates \
	wget \
	nano-tiny \
	imagemagick \
	libpq5 \
	unzip \
	postgresql-client \
	\
	bzr \
	mercurial \
	subversion \
	darcs \
	git \
	openssh-client \
	&& rm -rf /var/lib/apt/lists/*

RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		dirmngr \
		gnupg \
	; \
	rm -rf /var/lib/apt/lists/*; \
	\
	dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
	\
# grab gosu for easy step-down from root
# https://github.com/tianon/gosu/releases
	export GOSU_VERSION='1.10'; \
	wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
	wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
	export GNUPGHOME="$(mktemp -d)"; \
#	gpg --keyserver ha.pool.sks-keyservers.net --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 ; \
	for server in $(shuf -e ha.pool.sks-keyservers.net \
	        				hkp://p80.pool.sks-keyservers.net:80 \
	                        keyserver.ubuntu.com \
	                        hkp://keyserver.ubuntu.com:80 \
	                        pgp.mit.edu) ; do \
		gpg --keyserver "$server" --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 && break || : ; \
	done ; \
	gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
	gpgconf --kill all; \
	rm -r "$GNUPGHOME" /usr/local/bin/gosu.asc; \
	chmod +x /usr/local/bin/gosu; \
	gosu nobody true; \
	\
# grab tini for signal processing and zombie killing
# https://github.com/krallin/tini/releases
	export TINI_VERSION='0.18.0'; \
	wget -O /usr/local/bin/tini "https://github.com/krallin/tini/releases/download/v$TINI_VERSION/tini-$dpkgArch"; \
	wget -O /usr/local/bin/tini.asc "https://github.com/krallin/tini/releases/download/v$TINI_VERSION/tini-$dpkgArch.asc"; \
	export GNUPGHOME="$(mktemp -d)"; \
#	gpg --keyserver ha.pool.sks-keyservers.net --recv-keys 6380DC428747F6C393FEACA59A84159D7001A4E5 ; \
	for server in $(shuf -e ha.pool.sks-keyservers.net \
							hkp://p80.pool.sks-keyservers.net:80 \
							keyserver.ubuntu.com \
							hkp://keyserver.ubuntu.com:80 \
							pgp.mit.edu) ; do \
		gpg --keyserver "$server" --recv-keys 6380DC428747F6C393FEACA59A84159D7001A4E5 && break || : ; \
	done ; \
	gpg --batch --verify /usr/local/bin/tini.asc /usr/local/bin/tini; \
	gpgconf --kill all; \
	rm -r "$GNUPGHOME" /usr/local/bin/tini.asc; \
	chmod +x /usr/local/bin/tini; \
	tini -h; \
	\
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false


ENV RAILS_ENV production
WORKDIR /usr/src/redmine

ENV REDMINE_VERSION 3.4.6
ENV REDMINE_DOWNLOAD_MD5 5f4993446ecf25782f469763c0d32ea1

RUN wget -O redmine.tar.gz "https://www.redmine.org/releases/redmine-${REDMINE_VERSION}.tar.gz" \
	&& echo "$REDMINE_DOWNLOAD_MD5 redmine.tar.gz" | md5sum -c - \
	&& tar -xvf redmine.tar.gz --strip-components=1 \
	&& rm redmine.tar.gz files/delete.me log/delete.me \
	&& mkdir -p tmp/pdf public/plugin_assets \
	&& chown -R redmine:redmine ./

#install gems for redmine and plugins, install passenger
RUN set -eux; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		gcc \
		libmagickcore-dev \
		libmagickwand-dev \
		libpq-dev \
		make \
		g++ \
		cmake \
		autoconf \
		patch \
		libicu-dev \
		vim \
		; \
		rm -rf /var/lib/apt/lists/*; \
		\
		# add bundle setting and updates for install plugins
		bundle lock --add-platform x86-mingw32 x64-mingw32 x86-mswin32; \
		bundle install --without development test; \
		for adapter in postgresql; do \
			echo "$RAILS_ENV:" > ./config/database.yml; \
			echo "  adapter: $adapter" >> ./config/database.yml; \
			# add to Gemfile gems for required for plugins
			echo "gem 'sass', '~> 3.4.15'" >> ./Gemfile; \
			echo "gem 'copyright-header', '~> 1.0.8'" >> ./Gemfile; \
			echo "gem 'byebug'" >> ./Gemfile; \
			echo "gem 'multi_json'" >> ./Gemfile; \
			echo "gem 'activerecord-session_store'" >> ./Gemfile; \
			echo "gem 'liquid'" >> ./Gemfile; \
			echo "gem 'redmine_crm', '>= 0.0.38'" >> ./Gemfile; \
			echo "gem 'redmine_extensions'" >> ./Gemfile; \
			echo "gem 'rubyzip', '>= 1.0.0'" >> ./Gemfile; \
			echo "gem 'therubyracer'" >> Gemfile; \
			echo "gem 'slim'" >> Gemfile; \
 			echo "gem 'rspec-rails', '>= 3.5.2', '~> 3.5'" >> Gemfile; \
			echo "gem 'rubycritic'" >> Gemfile; \
			# add to Gemfile gem for install passenger
			echo "gem 'passenger', '=$PASSENGER_VERSION'" >> ./Gemfile; \
			bundle update; \
			bundle install --without development test; \
		    cp Gemfile.lock "Gemfile.lock.${adapter}"; \
			done; \
			rm ./config/database.yml; \
			# config passenger
			passenger-config build-native-support; \
			passenger-config install-agent; \
			passenger-config download-nginx-engine; \
			\
		# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
		apt-mark auto '.*' > /dev/null; \
		[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
		find /usr/local -type f -executable -exec ldd '{}' ';' \
			| awk '/=>/ { print $(NF-1) }' \
			| sort -u \
			| grep -v '^/usr/local/' \
			| xargs -r dpkg-query --search \
			| cut -d: -f1 \
			| sort -u \
			| xargs -r apt-mark manual \
		; \
		apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false

# download plugins and install need gems
RUN set -x \
	# add plugins for redmine
	&& cd plugins \
	#	sidebar_hide) \
	&& git clone https://github.com/jouve/sidebar_hide \
	#	fixed_header) \
	&& git clone https://github.com/YujiSoftware/redmine-fixed-header.git redmine_fixed_header \
	#	drawio) \
	&& git clone https://github.com/mikitex70/redmine_drawio.git \
	#	wiki_lists) \
	&& git clone https://github.com/tkusukawa/redmine_wiki_lists.git \
	#	theme_changer) \
	&& git clone https://github.com/haru/redmine_theme_changer.git \
	#	view_customize) \
	&& git clone https://github.com/onozaty/redmine-view-customize.git view_customize \
	#	wiki_extensions) \
	&& git clone https://github.com/haru/redmine_wiki_extensions.git \
	#	issue_id) \
	&& git clone https://github.com/s-andy/issue_id.git \
	#	issue_todo_lists) \
	&& git clone https://github.com/canidas/redmine_issue_todo_lists.git \
	#	redhopper) \
	&& git clone https://framagit.org/infopiiaf/redhopper.git \
	# code_review
	&& git clone https://github.com/haru/redmine_code_review \
	# local_avatars
	&& git clone https://github.com/ncoders/redmine_local_avatars \
	# recurring tasks
	&& git clone https://github.com/centosadmin/redmine_recurring_tasks.git \
	# redmine_banner
	&& git clone https://github.com/akiko-pusu/redmine_banner \
	# redmine_issue_templates
	&& git clone https://github.com/akiko-pusu/redmine_issue_templates \
	# Lightbox 2
	&& git clone https://github.com/paginagmbh/redmine_lightbox2.git \
	# redmine_hourglass - new version of time_tracker
	&& git clone https://github.com/hicknhack-software/redmine_hourglass \
	# remove string - "gem 'saas'" from Gemfile, for delete dependency error version >= 0, we have saas '~> 3.4.15'
	&& sed -i '/sass/d' redmine_hourglass/Gemfile \
	# get swagger-ui - is not redmine plugins, is assets for redmine_hourglass plugin (https://github.com/hicknhack-software/redmine_hourglass/issues/75)
	&& git clone https://github.com/swagger-api/swagger-ui.git \
	&& cd ./swagger-ui \
	&& git checkout v2.2.10 \
	&& cp -R ./dist ../redmine_hourglass/vendor/assets/javascripts \
	&& rm -fR ../swagger-ui \
	&& cd ../redmine_hourglass/vendor/assets/javascripts \
	&& mv ./dist ./swagger-ui \
	# add themes for redmine
	&& cd /usr/src/redmine/public/themes \
	# minimalflat2
	&& wget https://github.com/akabekobeko/redmine-theme-minimalflat2/releases/download/v1.3.6/minimalflat2-1.3.6.zip \
	&& unzip minimalflat2-1.3.6.zip \
	# flatly_light_redmine
	&& git clone https://github.com/Nitrino/flatly_light_redmine.git \
	# gitmike
	&& git clone https://github.com/makotokw/redmine-theme-gitmike.git \
	# minelab
	&& git clone https://github.com/jjanusch/minelab.git \
	# Redmine Alex skin - this recomended theme for all plugins from rmplus.pro plugins: usability and Unread issues
	&& git clone https://bitbucket.org/dkuk/redmine_alex_skin.git \
	&& cd ../.. \
	#     && rm plugins/easy_wbs/Gemfile \
	&& bundle install --no-cache --no-prune --without development test \
	# create directories to save the plugins
	# to able to restore these directories in the host directory mounted as binmount type at the start of the container
	&& mkdir plugins-storage \
	# move plugins to storages directories: plugins-storage
	# for clean plugins directory and can start redmine without plugins
	&& cp -r plugins/* plugins-storage \
	&& rm -rdf plugins/* \
	# create dir for store directories which are used to store changing data when initializing the database,
	# installing plugins, etc...  Extracting this dir only one time - first start
	&& mkdir public-storage tmp-storage db-storage \
	&& cp -r public/* public-storage \
	&& rm -rdf public/* \
	&& cp -r tmp/* tmp-storage \
	&& rm -rdf tmp/* \
	&& cp -r db/* db-storage \
	&& rm -rdf db/* \
	#Redmmine/wiki/RedmineInstall#Step-8-File-system-permissions
	&& chown -R redmine:redmine files log public plugins \
	# directories 755, files 644:
	&& chmod -R ugo-x,u+rwX,go+rX,go-w files log tmp public

COPY docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 3000
CMD ["passenger", "start"]
