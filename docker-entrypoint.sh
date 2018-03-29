#!/bin/bash
set -e

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

case "$1" in
	rails|rake|passenger)
		if [ ! -f './config/database.yml' ]; then
			file_env 'REDMINE_DB_MYSQL'
			file_env 'REDMINE_DB_POSTGRES'
			file_env 'REDMINE_DB_SQLSERVER'

			if [ "$MYSQL_PORT_3306_TCP" ] && [ -z "$REDMINE_DB_MYSQL" ]; then
				export REDMINE_DB_MYSQL='mysql'
			elif [ "$POSTGRES_PORT_5432_TCP" ] && [ -z "$REDMINE_DB_POSTGRES" ]; then
				export REDMINE_DB_POSTGRES='postgres'
			fi

			if [ "$REDMINE_DB_MYSQL" ]; then
				adapter='mysql2'
				host="$REDMINE_DB_MYSQL"
				file_env 'REDMINE_DB_PORT' '3306'
				file_env 'REDMINE_DB_USERNAME' "${MYSQL_ENV_MYSQL_USER:-root}"
				file_env 'REDMINE_DB_PASSWORD' "${MYSQL_ENV_MYSQL_PASSWORD:-${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}}"
				file_env 'REDMINE_DB_DATABASE' "${MYSQL_ENV_MYSQL_DATABASE:-${MYSQL_ENV_MYSQL_USER:-redmine}}"
				file_env 'REDMINE_DB_ENCODING' ''
			elif [ "$REDMINE_DB_POSTGRES" ]; then
				adapter='postgresql'
				host="$REDMINE_DB_POSTGRES"
				file_env 'REDMINE_DB_PORT' '5432'
				file_env 'REDMINE_DB_USERNAME' "${POSTGRES_ENV_POSTGRES_USER:-postgres}"
				file_env 'REDMINE_DB_PASSWORD' "${POSTGRES_ENV_POSTGRES_PASSWORD}"
				file_env 'REDMINE_DB_DATABASE' "${POSTGRES_ENV_POSTGRES_DB:-${REDMINE_DB_USERNAME:-}}"
				file_env 'REDMINE_DB_ENCODING' 'utf8'
			elif [ "$REDMINE_DB_SQLSERVER" ]; then
				adapter='sqlserver'
				host="$REDMINE_DB_SQLSERVER"
				file_env 'REDMINE_DB_PORT' '1433'
				file_env 'REDMINE_DB_USERNAME' ''
				file_env 'REDMINE_DB_PASSWORD' ''
				file_env 'REDMINE_DB_DATABASE' ''
				file_env 'REDMINE_DB_ENCODING' ''
			else
				echo >&2
				echo >&2 'warning: missing REDMINE_DB_MYSQL, REDMINE_DB_POSTGRES, or REDMINE_DB_SQLSERVER environment variables'
				echo >&2
				echo >&2 '*** Using sqlite3 as fallback. ***'
				echo >&2

				adapter='sqlite3'
				host='localhost'
				file_env 'REDMINE_DB_PORT' ''
				file_env 'REDMINE_DB_USERNAME' 'redmine'
				file_env 'REDMINE_DB_PASSWORD' ''
				file_env 'REDMINE_DB_DATABASE' 'sqlite/redmine.db'
				file_env 'REDMINE_DB_ENCODING' 'utf8'

				mkdir -p "$(dirname "$REDMINE_DB_DATABASE")"
				chown -R redmine:redmine "$(dirname "$REDMINE_DB_DATABASE")"
			fi

			REDMINE_DB_ADAPTER="$adapter"
			REDMINE_DB_HOST="$host"
			echo "$RAILS_ENV:" > config/database.yml
			for var in \
				adapter \
				host \
				port \
				username \
				password \
				database \
				encoding \
			; do
				env="REDMINE_DB_${var^^}"
				val="${!env}"
				[ -n "$val" ] || continue
				echo "  $var: \"$val\"" >> config/database.yml
			done
		else
			# parse the database config to get the database adapter name
			# so we can use the right Gemfile.lock
			adapter="$(
				ruby -e "
					require 'yaml'
					conf = YAML.load_file('./config/database.yml')
					puts conf['$RAILS_ENV']['adapter']
				"
			)"
		fi

		# ensure the right database adapter is active in the Gemfile.lock
		cp "Gemfile.lock.${adapter}" Gemfile.lock


		# install additional gems for Gemfile.local and plugins
		bundle check || bundle install --without development test

		# if  REDMINE_PLUGINS_MIGRATE=true, the start installing all plugins first time
		# or reinstall all plugins - need remove all existing plugins
		echo "REDMINE_INIT_PLUGINS_MIGRATE="$REDMINE_INIT_PLUGINS_MIGRATE
		if [[ $REDMINE_INIT_PLUGINS_MIGRATE ]]; then
		echo "Clean redmine plugins directory, delete all plugins if exist, for reinstall"
		rm -fRd plugins/*
		fi

		if [ ! -s config/secrets.yml ]; then
			file_env 'REDMINE_SECRET_KEY_BASE'
			if [ "$REDMINE_SECRET_KEY_BASE" ]; then
				cat > 'config/secrets.yml' <<-YML
					$RAILS_ENV:
					  secret_key_base: "$REDMINE_SECRET_KEY_BASE"
					echo "RAILS_ENV consist REDMINE_SECRET_KEY_BASE:"$RAILS_ENV
				YML
			elif [ ! -f /usr/src/redmine/config/initializers/secret_token.rb ]; then
				echo "rake generate secret key redmine base"
				#rake -f /usr/src/redmine/lib/tasks/initializers.rake -N -G --trace generate_secret_token
				rake generate_secret_token
				echo "rake secret complete"
			fi
		fi

		if [ "$1" != 'rake' -a -z "$REDMINE_NO_DB_MIGRATE" ]; then
			echo "redmine db migrate"
			gosu redmine rake db:migrate
			echo  "REDMINE_NO_DB_MIGRATE=true" >> .env
		fi

		if [ "$1" != 'rake' -a -n "$REDMINE_INIT_PLUGINS_MIGRATE" ]; then
			echo "start plugins:migrate"
			cp -r hide-plugins/* plugins
			chown -R redmine:redmine plugins

			# install additional gems for plugins
			echo "run bundle"
			bundle install --local --without development test

			echo "Start rake for compile assets"
			#	assets precompile
			rake assets:precompile db:migrate RAILS_ENV=production RAILS_GROUPS=assets

			echo "plugins db migrate"
			# db migrate for redmine plugins
			language=russian bundle exec rake redmine:plugins:migrate RAILS_ENV=production
			echo "Init plugins complete."

			echo "Deploy Redmine+Plugins+Passenger complete.  Starting Passenger..."
		fi

		if [ "$1" != 'rake' -a -n "$REDMINE_PLUGINS_UPDATE" ]; then
					language=russian bundle exec rake redmine:plugins:migrate RAILS_ENV=production
				fi

		#add redmine config file for emails configuration
  	# this config file will write after redmine db migrate and after plugins db migrate
		# if write this file before migration - migration fail
		echo "default:" > config/configuration.yml
		echo " email_delivery:" >> config/configuration.yml
		echo "   delivery_method: ${EMAIL_CONFIG_DELIVERY_METHOD}" >> config/configuration.yml
		echo "   smtp_settings:" >> config/configuration.yml
		for var in \
		 address \
		 port \
		 authentication \
		 domain \
		 user_name \
	 	 password \
		; do
			env="EMAIL_CONFIG_${var^^}"
			val="${!env}"
			[ -n "$val" ] || continue
	 	  echo "     $var: $val" >> config/configuration.yml
		done

  	# https://www.redmine.org/projects/redmine/wiki/RedmineInstall#Step-8-File-system-permissions
		chown -R redmine:redmine files log public/plugin_assets
		# directories 755, files 644:
		chmod -R ugo-x,u+rwX,go+rX,go-w files log tmp public/plugin_assets

		# remove PID file to enable restarting the container
		rm -f /usr/src/redmine/tmp/pids/server.pid

		if [ "$1" = 'passenger' ]; then
			# Don't fear the reaper.
			set -- tini -- "$@"
		fi

		set -- gosu redmine "$@"
		;;
esac

exec "$@"
