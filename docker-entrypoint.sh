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

# initialization of the RM, depending on the values of the variables
install_plugins() {
	# extract the plugins listed in REDMINE_PLUGINS_LIST from image, if empty - not extract any plugins
	local redmine_plugins_list="$@"

	# install plugins
	# switch bash to non stop run if return non zerro code
	# need because not all plugins consist in plugins-store (private plugins not present on this image)
	set +e
	# Copy selected plugins frome storage directory
	echo " Start plugins:migrate"
	if [[ $redmine_plugins_list ]] ; then
		echo " List plugins will be installed: "$redmine_plugins_list
		#copy plugins from hide-plugins dir
		for var in $redmine_plugins_list ;
		do
			echo -n $var
			cp -r plugins-storage/$var plugins && echo "- plugins copy Ok"
		done
	fi
	# switch bash to stop mode if return non zerro code
	set -e

	#Redmmine/wiki/RedmineInstall#Step-8-File-system-permissions
	chown -R redmine:redmine plugins
	# directories 755, files 644:
	chmod -R ugo-x,u+rwX,go+rX,go-w plugins

	# install additional gems for plugins
	echo " run bundle install"
	bundle install --without development test

	if [[ -z $redmine_plugins_list ]]; then
		echo "REDMINE_PLUGINS_LIST is empty, start/upgrade Redmine without any plugins"
	else
		echo "Installing plugins from REDMINE_PLUGINS_LIST"
		# db migrate for redmine plugins
		echo " Start plugins db migrate "
		languge=russian	bundle exec rake redmine:plugins:migrate RAILS_ENV=production
		# install assets for redmine plugins
		echo " Start install redmine plugins assets"
		bundle exec rake redmine:plugins:assets RAILS_ENV=production
	fi
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


		#check for exist redmine database on PostgreSQL
		PGPASSWORD=$REDMINE_DB_PASSWORD psql -h $REDMINE_DB_POSTGRES -p 5432 -U $REDMINE_DB_USERNAME -d $REDMINE_DB_DATABASE -l || db_redmine_not_exist=1
		if [[ $db_redmine_not_exist ]] ; then
			echo ""
			echo "  Database for Redmine with name: "$REDMINE_DB_DATABASE" in PostgreSQL server: "$REDMINE_DB_POSTGRES" NOT exist - exit"
			echo " "
			exit 1
		else
			echo " Database for Redmine with name: "$REDMINE_DB_DATABASE" in PostgreSQL server: "$REDMINE_DB_POSTGRES" - exist, starting Redmine"
			echo " "
	  	fi

		#set redmine table for check, if exist - the redmine and plugins database are initializers
		REDMINE_DB_TABLE_NAME=issues
		# check for exist table - try to craete redmine table, if succsessfull, need delete the table for Redmine DB migration succsess
		PGPASSWORD=$REDMINE_DB_PASSWORD psql -e -h $REDMINE_DB_POSTGRES -p 5432 -U $REDMINE_DB_USERNAME -d $REDMINE_DB_DATABASE -c "CREATE TABLE $REDMINE_DB_TABLE_NAME ( name varchar(10));" || redmine_db_table_exist=1
		#check make_import table, if exist - do init procedure and copy files from files, pdf and other directory
 		#TODO add functionality for copy files from public directory from imported version redmine
		PGPASSWORD=$REDMINE_DB_PASSWORD psql -e -h $REDMINE_DB_POSTGRES -p 5432 -U $REDMINE_DB_USERNAME -d $REDMINE_DB_DATABASE -c "CREATE TABLE make_import ( name varchar(10));" || make_import_db_table_exist=1
		# drop table, for run redmine container normal mode next time
		PGPASSWORD=$REDMINE_DB_PASSWORD psql -e -h $REDMINE_DB_POSTGRES -p 5432 -U $REDMINE_DB_USERNAME -d $REDMINE_DB_DATABASE -c "DROP TABLE make_import;"
		# check for new deploy RM, start init derectories
		# restore directories when use for store data when changing during use Redmine
		# files and tmp - the directory for store data when describe to redmine docs
		# public consist plugin_assets, javascripts and themes - the directory also use for store data during use Redmine
		if [[ -z $redmine_db_table_exist || $make_import_db_table_exist ]] ; then
			#clear directory, for new installation or update procedure
			echo -n "Clean directory: public, tmp,db and plugins for new deploy or import existing base"
			rm -fRd puplic/* && echo "- clean Ok"
			rm -fRd tmp/* && echo "-clean ok"
			rm -frd db/* && echo "-clean ok"
			rm -frd plugins/* && echo "-clean ok"
			echo "Restore public tmp adn db directory from image (new deploy)"
			cp -r public-storage/* public
			cp -r tmp-storage/* tmp
			cp -r db-storage/* db
			#Redmmine/wiki/RedmineInstall#Step-8-File-system-permissions
			chown -R redmine:redmine tmp public db
			# directories 755, files 644:
			chmod -R ugo-x,u+rwX,go+rX,go-w tmp public db
		fi


		# ensure the right database adapter is active in the Gemfile.lock
		cp "Gemfile.lock.${adapter}" Gemfile.lock

		# check for need install additional gems for Gemfile.local
		bundle check || bundle install --without development test

		# config secret token for redmine
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
				bundle exec rake generate_secret_token
				echo "rake secret complete"
			fi
		fi

		# init redmine and plugins
		if [[ $redmine_db_table_exist ]]; then
			# Redmine started with imported database from other system, need copy files from files,pdf and TODO public
			if [[ $make_import_db_table_exist ]]; then
				echo "Redmine starting with imported database, start copy files from files, pdf directory"
				# restore plugins migrate
				install_plugins "$REDMINE_PLUGINS_LIST"
				# clear the cahe and the existing sessions
				bundle exec rake tmp:cache:clear tmp:sessions:clear RAILS_ENV=production
				# copy files from folder /tmp/redmineprev
				gosu redmine cp -r /tmp/redmine-import/files/* files/
				gosu redmine cp -r /tmp/redmine-import/tmp/pdf/* tmp/pdf
				echo "Directory: files, pdf - copy complete"
			else
				echo " make_import table don't exist, start Redmine in normal mode"
			fi
		else
			echo " $REDMINE_DB_TABLE_NAME table not exist in "$REDMINE_DB_POSTGRES", deploy Redmine and Plugins migration database. Droping a test table."
			# remove table REDMINE_DB_TABLE_NAME
			PGPASSWORD=$REDMINE_DB_PASSWORD psql -h $REDMINE_DB_POSTGRES -p 5432 -U $REDMINE_DB_USERNAME -d $REDMINE_DB_DATABASE -c "DROP TABLE $REDMINE_DB_TABLE_NAME"
			# create database structure or migrate structure from prevision version
			echo " Start create redmine database structure"
			RAILS_ENV=prod gosu redmine echo " test gosu RAILS_ENV="$RAILS_ENV
			bundle exec rake db:migrate RAILS_ENV=production
			#assets precompile for redmine
			echo " Start precompile redmine assets "
			bundle exec rake assets:precompile db:migrate RAILS_ENV=production RAILS_GROUPS=assets
			#install redmine plugins
			install_plugins "$REDMINE_PLUGINS_LIST"
		fi

		echo " "
		echo " Deploy Redmine+Plugins+Passenger complete.  Starting Passenger... "
		echo " "

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
		chown -R redmine:redmine files log plugins public/plugin_assets
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
