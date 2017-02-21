bz2redmine
========================================================================

bz2redmine is a script to convert your existing bugzilla database to 
a redmine database. 

Bugzilla is a popular Bugtracking-System. 

Redmine is a increaingly popular bugtracking system as well. 
Compared with Bugzilla,Redmine has a couple of unique features.

Parts of the script (especially many of the SQL-statements) are based 
on the bz2redmine.php-Script by Robert Heath. See the CREDITS file for
details. 

You can find Bugzilla here: http://www.bugzilla.org

You can find Redmine here: http://www.redmine.org

Features
---------------------------------------------------------------------------

* Preserves the Bugzilla bug numbers
* Converts most of the existing Bugzilla data including attachments
* Has been successfully used to convert a Bugzilla 4.2.1 to Redmine 3.3
* This fork uses the new __mysql2__ Driver to provide performance. (__mysql__ is deprecated)

Usage
---------------------------------------------------------------------------

* Backup your Databases and your existing redmine installation. 
  The script will delete all of the data of your existing redmine installation.
* If you are working on a new installation of redmine make shure you ran
  "rake redmine:load_default_data"
* Copy the settings.rb.example file to settings.rb and modify the settings
  to match your needs.
* run the script

According to Alexander Zhovnuvaty the following additional steps are
needed to finish the migration:

Aditional Steps
---------------------------------------------------------------------------
* Grant administrator permissions to certain users. In this particular case for users with 1, 13 ids;

    update users set admin = true where id in (1, 13);
 
 
 Special Usage
 ---------------------------------------------------------------------------
 
 * The tables to be migrated can be customized changing "def migrate". Commenting blocks of calls excepts parts of the migration

