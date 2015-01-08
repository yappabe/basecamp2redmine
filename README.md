# Basecamp 2 Redmine Migration

This Ruby script will extract data from a Basecamp "backup" XML file and import it into Redmine.

Inspired by https://github.com/tedb/basecamp2redmine

##  Get Ready to Run

Before running this script:

* Create Trackers inside Redmine called "Bug" and "Todo List".
* Fill `users_map` array with basecamp user ids => Redmine users

## Database Correction and .sql files

Backup the entire database before making any changes.

Temporarily delete the following unique index on a join table:

```
ALTER TABLE `projects_trackers` DROP INDEX `projects_trackers_unique`;
```

Once you're finished with this import, you can get your unique values/keys with the following SQL statements:

```
CREATE TABLE `projects_trackers_distinct` SELECT distinct * FROM `projects_trackers`;
TRUNCATE TABLE `projects_trackers`;
ALTER TABLE `projects_trackers` ADD UNIQUE KEY `projects_trackers_unique` (`project_id`,`tracker_id`);
INSERT INTO `projects_trackers` SELECT * FROM `projects_trackers_distinct`;
DROP TABLE `projects_trackers_distinct`
```
## Running this script, creating the import file

This script, if saved as filename basecamp2redmine.rb, can be invoked as follows.
This will generate an ActiveRecord-based import script in the current directory, which should be the root directory of the Redmine installation.

```
ruby basecamp2redmine.rb basecamp-export.xml > migration.rb
```

You can edit the newly created file *migration.rb* or at least review it.
Place it in the root folder of your redmine installation.

```
rails runner migration.rb
```