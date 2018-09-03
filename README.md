
# dockerfile Redmine  

  Redmine v3.4.6 dockerfile for build image with plugins, themes and passenger.
  This image create for use with [dcape](https://github.com/dopos/dcape) and Postgresql database,
  which is used as part of the dcape.

  Image usage variants.
  1. The use of the image for the initial release of the Redmine system (deploy with empty database)
  2. Deploy Redmine and import of the existing database from the used version of the Redmine.

  All variants can use without any plugina or using plugins of you choice from the list specified here.

  # List Redmine plugins

  ## Interface

  * [x] http://www.redmine.org/plugins/redmine_theme_changer - v0.3.1
  * [x] http://www.redmine.org/plugins/redmine_user_specific_theme - v1.2.0
  * [x] http://www.redmine.org/plugins/redmine_view_customize - v1.1.4
  * [x] http://www.redmine.org/plugins/redmine_wiki_lists - v0.0.9
  * [x] http://www.redmine.org/plugins/redmine_wiki_extensions - v0.8.1
  * [x] http://www.redmine.org/plugins/sidebar_hide - v0.0.8  
  * [x] http://www.redmine.org/plugins/issue_id - v0.0.2
  * [x] http://www.redmine.org/plugins/redmine-fixed-header - v1.0.0
  * [x] http://www.redmine.org/plugins/redmine_drawio - v0.8.1
  * [x] http://www.redmine.org/plugins/redmine_local_avatars - v0.1.1

  ## Functional

  * [x] http://www.redmine.org/plugins/redmine_issue_todo_lists - v1.1.2
  * [x] https://www.redmine.org/plugins/redmine_code_review - v0.9.0
  * [x] https://github.com/hicknhack-software/redmine_hourglass - v1.2.0  

  ## Future

  * [x] http://www.redmine.org/plugins/redhopper - v1.0.11.

  ## Themes that are included in the image

  * [x] [Redmine Minimalflat2](https://github.com/akabekobeko/redmine-theme-minimalflat2)
  * [x] [Flatly light](https://github.com/Nitrino/flatly_light_redmine)
  * [x] [Gitmike](https://github.com/makotokw/redmine-theme-gitmike)
  * [x] [Minelab](https://github.com/jjanusch/minelab)
  * [x] [Redmine Alex skin](https://bitbucket.org/dkuk/redmine_alex_skin.git)

  All plugins from list store in image and need copy and install during startup redmine.
  Managing the installation of plugins is done through variables.



For manage the start of the redmine use variables:
	REDMINE_PLUGINS_LIST - list of plugins that can be installed, if not initialized, no plugins will be installed
	REDMINE_UPGRADE_FROM_PREV - if set, the existing database from previous version is migrated by the redmine update procedure

 Managing image startup.
  1. The initial deployment of the Redmine. Variable REDMINE_UPGRADE_FROM_PREV must be not set.
  Steps at initial start-up:
	 - check the availability of 'issue_categories' table in  REDMINE_DB_DATABASE
	 - if the table in database exist, go to normal start (3)
	 - if the table does not exist - create the database structure for Redmine
	 - check REDMINE_PLUGINS_LIST, if not set - plugins are not install; if set -
	   install and migrate redmine plugins from REDMINE_PLUGINS_LIST
  2. Updating Redmine, starting with the existing database from the previous version of the Redmine.
  	Need set REDMINE_UPGRADE_FROM_PREV.
	Steps at initial start-up:
	   - if set REDMINE_UPGRADE_FROM_PREV, start upgrade Redmine procedure
	   - check REDMINE_PLUGINS_LIST, if not set - plugins are not install; if set -
		 install and migrate redmine plugins from REDMINE_PLUGINS_LIST

  3. Normal start. REDMINE_UPGRADE_FROM_PREV must be not set.

The contents of the directory are db, public, tmp, files, changes during the deployment and operation of
the Redmine. The location of these directories is assumed on separate volumes, the contents of which are preserved
when the containers is deleted.

TODO add requirements for recurring_tasks plugins 
