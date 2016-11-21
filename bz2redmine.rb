#!/usr/bin/ruby
#
# Copyright (c) 2009, Ralph Juhnke
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification,
# are permitted provided that the following conditions are met:
#
#    1. Redistributions of source code must retain the above copyright notice,
#       this list of conditions and the following disclaimer.
#    2. Redistributions in binary form must reproduce the above copyright notice,
#       this list of conditions and the following disclaimer in the documentation and/or other
#       materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
# EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
# ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

# For Redmine 3 or upper (changed email update)
# 

require "rubygems"
require "mysql2"
require File.expand_path(File.join(File.dirname(__FILE__), "settings"))
require "digest/sha1"

# Connection Info
class ConnectionInfo
  attr_accessor :host
  attr_accessor :user
  attr_accessor :password
  attr_accessor :dbname
  attr_accessor :encoding
  
  def initialize(host, user, password, dbname,encoding)
    @host = host
    @user = user
    @password = password
    @dbname = dbname
	@encoding = encoding
  end
end

# Main Class
class BugzillaToRedmine

# Startup
  def initialize
    @bugzillainfo =  ConnectionInfo.new(BUGZILLA_HOST, BUGZILLA_USER, BUGZILLA_PASSWORD, BUGZILLA_DB, BUGZILLA_ENCODING)
    @redmineinfo = ConnectionInfo.new(REDMINE_HOST, REDMINE_USER, REDMINE_PASSWORD, REDMINE_DB, REDMINE_ENCODING)

    # Bugzilla priority to Redmine priority map
    @issuePriorities = ISSUE_PRIORITIES

    # Bugzilla severity to Redmine tracker map
    @issueTrackers = ISSUE_TRACKERS

    # Bugzilla status to Redmine status map
    @issueStatus = ISSUE_STATUS

	# User default lang
	@defaultLanguage = REDMINE_DEFAULT_LANG
	
    # create hashcode for default password
    @passwordSalt = "" 
    @defaultPassword = Digest::SHA1::hexdigest(@passwordSalt+Digest::SHA1::hexdigest(REDMINE_DEFAULT_USER_PASSWORD))
  end

  # Process Guide
  # If process fail in one of the define blocks you could comment the previous blocks 
  # and launch again to continue
  def migrate
    self.open_connections
    self.perform_sanity_checks
	
	# BLOCK: Base, projects and versions
    # self.clear_redmine_tables
    # self.migrate_projects
    # self.migrate_versions
	
	# BLOCK: Uses
	#self.clear_redmine_users
    #self.migrate_users
    #self.migrate_groups
    #self.migrate_members
    #self.migrate_member_roles
    #self.migrate_groups_users
	
	# BLOCK: Issues
	#self.migrate_categories
    self.migrate_issues
    self.migrate_time_entries
    self.migrate_watchers
    self.migrate_issue_relations
	
	# BLOCK: Attachments
    self.migrate_attachments
	
	# End
    self.close_connections
  end

# Log helper function
  def log(s)
    puts s
  end

  def sql_log(s)
	puts s
  end
  
# Mysql Operations
  def open_connection(info)
    self.log "opening #{info.inspect}"
	db = Mysql2::Client.new(
		:host=>info.host, 
		:username=>info.user,
		:password=>info.password, 
		:database=>info.dbname,
		:encoding=>info.encoding,
		:reconnect=>true
	)
    return db
  end
  
  def bz_select_sql(sql, *args, &block)
    self.sql_log("bugzilla: #{sql} args=#{args.join(',')}")
    statement = @bugzilladb.prepare(sql)
	results = statement.execute(*args)
	results.each(:as => :array) do |row|
		yield row
	end
	statement.close()
  end

  def red_exec_sql(sql, *args)
    self.sql_log("redmine: #{sql} args=#{args.join(',')}")
    statement = @redminedb.prepare(sql)
    statement.execute(*args)
    statement.close()
  end

  def red_select_sql(sql, *args, &block)
    self.sql_log("redmine: #{sql} args=#{args.join(',')}")
    statement = @redminedb.prepare(sql)
	results = statement.execute(*args)
	results.each(:as => :array) do |row|
		yield row
	end
    statement.close()
  end
  
  def red_check_exists(sql, *args)
    self.red_select_sql(sql, *args) { |i|  return true }
    return false
  end

# Migration operations in migrate process (view migrate funcion)
  def open_connections
    self.log("Opening connections")
    @bugzilladb = self.open_connection(@bugzillainfo)
    @redminedb = self.open_connection(@redmineinfo)
  end

  def close_connections
    self.log "closing database connections"
    @bugzilladb.close
    @redminedb.close
  end
  
  def clear_redmine_tables
	self.log("Clear redmine tables")
    sqls = [
      "DELETE FROM projects",
      "DELETE FROM projects_trackers",
      "DELETE FROM enabled_modules",
      "DELETE FROM boards",
      "DELETE FROM custom_fields_projects",
      "DELETE FROM documents",
      "DELETE FROM news",
      "DELETE FROM queries",
      "DELETE FROM repositories",
      "DELETE FROM time_entries",
      "DELETE FROM wiki_content_versions",
      "DELETE FROM wiki_contents",
      "DELETE FROM wiki_pages",
      "DELETE FROM wiki_redirects",
      "DELETE FROM wikis",
    ]
    sqls.each do |sql|
      self.red_exec_sql(sql)
    end
  end

  def clear_redmine_users
	self.log("Clear redmine users")
    ["DELETE FROM users",
      "DELETE FROM email_addresses",
      "DELETE FROM user_preferences",
      "DELETE FROM members",
      "DELETE FROM member_roles",
      "DELETE FROM groups_users",
      "DELETE FROM messages",
      "DELETE FROM tokens",
      "DELETE FROM watchers"].each do |sql|
      self.red_exec_sql(sql)
    end
  end
  
  def migrate_projects
	self.log("Migrate projects")
    tree_idx = 1
    self.bz_select_sql("SELECT products.id, products.name, products.description, products.classification_id, classifications.name as classification_name FROM products, classifications WHERE products.classification_id = classifications.id order by products.name") do |row|
      identifier = row["name"].downcase
      status = row["classification_id"] == 1 ? 9 : 1
      created_at = self.find_min_created_at_for_product(row["id"])
      updated_at = self.find_max_bug_when_for_product(row["id"])
      self.red_exec_sql("INSERT INTO projects (id, name, description, is_public, identifier, created_on, updated_on, status, lft, rgt) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", 
      row["id"], row["name"], row["description"], 1, identifier,created_at, updated_at, status, tree_idx, tree_idx+1)
      tree_idx = tree_idx + 2
      tree_idx = tree_idx + 2
      self.insert_project_trackers(row["id"])
      self.insert_project_modules(row["id"])
    end
  end

  def find_min_created_at_for_product(product_id)
    bug_when = '1970-01-01 10:22:25'
    self.bz_select_sql("select min(b.creation_ts) as ct from products p join bugs b on b.product_id = p.id where product_id=?", product_id) do |row|
      bug_when = row["ct"]
    end
    return bug_when
  end

  def find_max_bug_when_for_product(product_id)
    bug_when = '1970-01-01 10:22:25'
    sql = "select max(l.bug_when) as ct from products p join bugs b on b.product_id = p.id join longdescs l on l.bug_id = b.bug_id where b.product_id=?"
    self.bz_select_sql(sql, product_id) do |row|
      bug_when = row["ct"]
    end
    return bug_when
  end

  def migrate_versions
	self.log("Migrate Versions")
    self.red_exec_sql("delete from versions")
    self.bz_select_sql("SELECT id, product_id, value FROM versions") do |row|
      self.red_exec_sql("INSERT INTO versions (id, project_id, name) VALUES (?, ?, ?)", row["id"], row["product_id"], row["value"])
    end
  end

  def migrate_users
	self.log("Migrate Users")
    if not REDMINE_DEFAULT_AUTH_SOURCE_ID.nil?
      ldap = Net::LDAP.new :host => REDMINE_LDAP['host'], # your LDAP host name or IP goes here,
        :port => REDMINE_LDAP['port'], # your LDAP host port goes here,
        :base => REDMINE_LDAP['base'], # the base of your AD tree goes here,
        :auth => {
          :method => :simple,
          :username => REDMINE_LDAP['bind_user'], # a user w/sufficient privileges to read from AD goes here,
          :password => REDMINE_LDAP['bind_pass'] # the user's password goes here
        }
      raise "LDAP bind failed." unless ldap.bind
    end

    self.bz_select_sql("SELECT userid, login_name, realname, disabledtext, extern_id FROM profiles") do |row|
      user_id = row["userid"]
      login_name = row["login_name"]
      real_name = row["realname"]
      disabled_text = row["disabledtext"]
      extern_id = row["extern_id"]
      email = row["login_name"]
      if real_name.nil?
        (last_name, first_name) = ['empty', 'empty']
      else
        (last_name, first_name) = real_name.split(/[ ,]+/)
        if first_name.to_s.strip.empty?
          first_name = 'empty'
        end
        if last_name.to_s.strip.empty?
          last_name = 'empty'
        end
      end

      status = disabled_text.to_s.strip.empty? ? 1 : 3

      # Extern LDAP
      if not extern_id.nil? and not REDMINE_DEFAULT_AUTH_SOURCE_ID.nil?
        search_filter = Net::LDAP::Filter.eq(REDMINE_LDAP['email_attr'], login_name)
        self.log("Searching LDAP for %s" % login_name)
        result = ldap.search(:filter => search_filter, :attributes => [REDMINE_LDAP['login_attr']], :return_result => true) do |user|
          self.log("User found in LDAP")
          self.red_exec_sql("INSERT INTO users (id, login, firstname, lastname, language, mail_notification, status, type, auth_source_id) values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            user_id, user[REDMINE_LDAP['login_attr']].first, last_name, first_name, @defaultLang, 'only_my_events', status, 'User', REDMINE_DEFAULT_AUTH_SOURCE_ID)
        end
      end

      # Local
      if result.nil? or extern_id.nil?
        self.red_exec_sql("INSERT INTO users (id, login, firstname, lastname, language, mail_notification, status, hashed_password, type, salt) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          user_id, login_name, last_name, first_name, @defaultLang, 'only_my_events', status, @defaultPassword, 'User', @passwordSalt)
      end

      other = """---
:comments_sorting: asc
:no_self_notified: true
      """
      self.red_exec_sql("INSERT INTO user_preferences (user_id,others) values (?, ?)", user_id, other)

      # Add Email
      self.red_exec_sql("INSERT INTO email_addresses(user_id,address,is_default,notify) VALUES(?,?,1,1)",user_id,email)
    end
  end
  
  def migrate_groups
	self.log("Migrate Groups")
    self.bz_select_sql("select name from groups") do |row|
      name = row["name"]
      self.red_exec_sql("insert into users (lastname, mail_notification, admin, status, type, language) values (?, ?, ?, ?, ?, ?)",
        name, 'only_my_events', (name == 'admin' ? 1 : 0) , 1, 'Group', @defaultLang)
    end
  end

  def find_version_id(project_id, version)
    result = -1
    self.red_select_sql("select id from versions where project_id=? and name=?", project_id, version) do |row|
      result = row["id"]
    end
    return result
  end

  def find_max_bug_when(bug_id)
    bug_when = '1970-01-01 10:22:25'
    self.bz_select_sql("select max(bug_when) as ct from longdescs where bug_id=?", bug_id) do |row|
      bug_when = row["ct"]
    end
    return bug_when
  end

  def migrate_categories
	self.log("Migrate Categories")
    self.red_exec_sql("delete from issue_categories")
    self.bz_select_sql("SELECT id, name, product_id, initialowner FROM components") do |row|
      self.red_exec_sql("INSERT INTO issue_categories (id, name, project_id, assigned_to_id) VALUES (?, ?, ?, ?)", row["id"], row["name"], row["product_id"], row["initialowner"])
    end
  end

  def migrate_watchers
	self.log("Migrate watchers")
    self.red_exec_sql("delete from watchers")
    self.bz_select_sql("select bug_id, who FROM cc") do |row|
      self.red_exec_sql("insert into watchers (watchable_type, watchable_id, user_id) values (?, ?, ?)", 'Issue', row["bug_id"], row["who"])
    end
  end

  def migrate_custom_fields
	self.log("Migrate custom fields")
    self.red_exec_sql("delete from custom_fields")
    self.red_exec_sql("delete from custom_fields_trackers")
    self.red_exec_sql("delete from custom_values")
    self.red_exec_sql("INSERT INTO custom_fields (id, type, name, field_format, possible_values, max_length, is_for_all, is_filter, searchable, default_value) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", 1, 'IssueCustomField', 'URL', 'string', '--- []/n/n', 255, 1, 1, 1, '')
    [1,2,3].each do |tracker_id|
      self.red_exec_sql("INSERT INTO custom_fields_trackers (custom_field_id, tracker_id) VALUES (?, ?)", 1, tracker_id)
    end
  end

  def migrate_time_entries
    self.log("Migrate time entries")
    self.red_exec_sql("delete from time_entries")
    self.bz_select_sql("select
  			b.product_id as project_id,
  			a.who as user_id,
  			a.bug_id as issue_id,
  			a.work_time as hours,
  			substr(a.thetext,1,255) as comments,
  			9 as activity_id,
  			date(bug_when) as spent_on,
  			year(bug_when) as tyear,
  			month(bug_when) as tmonth,
  			week(bug_when) as tweek,
  			bug_when as created_on,
  			bug_when as updated_on
  		from
  			longdescs a inner join bugs b on b.bug_id = a.bug_id
  		where work_time <> 0") do |row|
    project_id = row["project_id"]
    user_id = row["user_id"]
    issue_id = row["issue_id"]
    hours = row["hours"]
    comments = row["comments"]
    activity_id = row["activity_id"]
    spent_on = row["spent_on"]
    tyear = row["tyear"]
    tmonth = row["tmonth"]
    tweek = row["tweek"]
    created_on = row["created_on"]
    updated_on = row["updated_on"]
    self.red_exec_sql("insert into time_entries (project_id, user_id, issue_id, hours, comments, activity_id, spent_on, tyear, tmonth, tweek, created_on, updated_on) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      project_id, user_id, issue_id, hours, comments, activity_id, spent_on, tyear, tmonth, tweek, created_on, updated_on)
  end
 end

  def migrate_issues
    self.log("Migrate Issues")
    self.red_exec_sql("delete from issues")
    self.red_exec_sql("delete from journals")
    self.migrate_custom_fields
    sql = "SELECT b.bug_id, b.assigned_to, b.bug_status, b.creation_ts, b.short_desc, b.product_id,
               b.reporter, b.version, b.estimated_time, b.remaining_time,
               b.deadline, b.bug_severity, b.priority, b.component_id,
               b.bug_file_loc,ld.comment_id,ld.thetext,ld.bug_when,ld.who
               FROM bugs b, longdescs ld WHERE b.bug_id = ld.bug_id ORDER BY b.bug_id, ld.bug_when"
    current_bug_id = -1
	
	bug_id = nil
	estimated_time= nil
	remaining_time= nil
	
	sql_issue   = "INSERT INTO issues (id, project_id, subject, description, assigned_to_id, author_id, created_on, updated_on, start_date, due_date, done_ratio, estimated_hours, priority_id, fixed_version_id, category_id, tracker_id, status_id, root_id, lft, rgt) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
	sql_custom  = "INSERT INTO custom_values (customized_type, customized_id, custom_field_id, value)  VALUES (?, ?, ?, ?)";
	sql_journal = "INSERT INTO journals (id, journalized_id, journalized_type, user_id, notes, created_on)  VALUES (?, ?, ?, ?, ?, ?)";
	
    self.bz_select_sql(sql) do |row|
      bug_id = row["bug_id"]

      if(current_bug_id != bug_id)
	  
	    estimated_time= row["estimated_time"]
        remaining_time= row["remaining_time"]
		
        target_milestone_id = self.find_version_id(row["product_id"], row["version"])
        updated_at = self.find_max_bug_when(bug_id)
        priority_id = map_priority(bug_id, row["priority"])
        tracker_id = map_tracker(bug_id, row["bug_severity"])
        status_id = map_status(bug_id, row["bug_status"])
        done_ratio = estimated_time.to_f.abs < 1e-3 ? 0.00 : ((estimated_time.to_f - remaining_time.to_f)/estimated_time.to_f)*100
		
        self.red_exec_sql(sql_issue, bug_id, row["product_id"], row["short_desc"], row["thetext"], row["assigned_to"], row["reporter"], row["creation_ts"],  updated_at, 
			row["creation_ts"], row["deadline"], done_ratio, estimated_time, priority_id, target_milestone_id, row["component_id"] , tracker_id, status_id, bug_id, 1, 2)
			
        self.red_exec_sql(sql_custom, 'Issue', bug_id, 1, row["bug_file_loc"])
		
		current_bug_id = bug_id

		#GC.start
      else
        self.red_exec_sql(sql_journal, row["comment_id"], bug_id, "Issue", row["who"], row["thetext"], row["bug_when"])
      end
    end
  end

  def map_priority(bug_id, priority)
    priority_id = @issuePriorities[priority]
    throw "bugzilla bug #{bug_id}: cannot map the issue priority #{priority}." if priority_id.nil?
    return priority_id
  end

  def map_tracker(bug_id, bug_severity)
    return @issueTrackers[bug_severity] || 1 # use the "bug" tracker, if the bug severity does not match
  end

  def map_status(bug_id, bug_status)
    status_id = @issueStatus[bug_status]
    throw "bugzilla bug #{bug_id}: cannot map the issue priority #{bug_status}." if status_id.nil?
    return status_id
  end

  def migrate_issue_relations
    self.log("Migrate Issue relations")
    self.red_exec_sql("delete from issue_relations")
    self.bz_select_sql("SELECT dependson, blocked FROM dependencies") do |row|
      self.red_exec_sql("INSERT INTO issue_relations (issue_from_id, issue_to_id, relation_type) values (?, ?, ?)", row["dependson"], row["blocked"], "blocks")
    end
    self.bz_select_sql("SELECT dupe, dupe_of FROM duplicates") do |row|
      self.red_exec_sql("INSERT INTO issue_relations (issue_from_id, issue_to_id, relation_type) values (?, ?, ?)", row["dupe"], row["dupe_of"], "duplicates")
    end
  end

  def migrate_attachments
    self.log("Migrate attachments")
    self.red_exec_sql("DELETE FROM attachments")
    sql = "SELECT a.attach_id, a.bug_id, a.filename, a.mimetype, a.submitter_id, a.creation_ts, a.description, ad.thedata FROM attachments a, attach_data ad WHERE a.attach_id = ad.id"
	attach_id = nil
	bug_id = nil
	filename = nil
	mimetype = nil  
	submitter_id= nil
	creation_ts= nil
	description= nil 
	thedata = nil
	disk_filename = nil
	filesize=0
	sql_insert = "INSERT INTO attachments (id, container_id, container_type, filename, filesize, disk_filename, content_type, digest, downloads, author_id, created_on, description) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    self.bz_select_sql(sql) do |row|
      attach_id = row["attach_id"]
	  bug_id = row["bug_id"]
	  filename = row["filename"] 
	  mimetype = row["mimetype"]  
	  submitter_id= row["submitter_id"]  
	  creation_ts= row["creation_ts"] 
	  description= row["description"]  
	  thedata = row["thedata"]  
      disk_filename = self.get_disk_filename(attach_id, filename)
      filesize = thedata.size()
      self.red_exec_sql(sql_insert, attach_id, bug_id, 'Issue', filename, filesize, disk_filename, mimetype, '', 0, submitter_id, creation_ts, description)
	  self.log("Writting #{ATTACHMENT_PATH}/#{disk_filename}")
      File.open("#{ATTACHMENT_PATH}/#{disk_filename}", "wb") do |f|
        f.write(thedata)
      end
    end
  end

  def get_disk_filename(attach_id, filename)
    return "a#{attach_id}.#{self.get_file_extension(filename)}".downcase
  end

  def get_file_extension(s)
    m = /\.(\w+)$/.match(s)
    if(m)
      return m[1]
    else
      return 'dat'
    end
  end

  def migrate_members
    self.log("Migrate members")
    self.bz_select_sql("SELECT DISTINCT user_group_map.user_id, group_control_map.product_id FROM group_control_map, user_group_map WHERE group_control_map.group_id = user_group_map.group_id") do |row|
      user_id = row["user_id"]
      product_id = row["product_id"]
      role_id = DEFAULT_ROLE_ID
      created_on = "2007-01-01 12:00:00"
      mail_notification = 0
      self.red_exec_sql("INSERT INTO members (user_id, project_id, created_on, mail_notification) VALUES (?,?,?,?)", user_id, product_id, created_on, mail_notification)
    end
  end

  def select_group_id(group_name)
    result = nil
    red_select_sql("select id from users where lastname=? and type=?", group_name, 'Group') do |row|
      result = row["id"]
    end
    result
  end

  def select_last_insert_id
    result = 0
    red_select_sql("select last_insert_id() as ct") do |row|
		self.log("LAST_INSERT_ID: #{row}")
      result = row["ct"]
    end
    result
  end

  def migrate_member_roles
    self.log("Migrate member roles")
    self.bz_select_sql("SELECT DISTINCT groups.name, group_control_map.product_id FROM group_control_map, groups WHERE groups.id = group_control_map.group_id") do |row|
      group_name = row["name"]
      product_id = row["product_id"]
      role_id = DEFAULT_ROLE_ID
      created_on = "2007-01-01 12:00:00"
      mail_notification = 0
      group_id = select_group_id(group_name)
      self.red_exec_sql("INSERT INTO members (user_id, project_id, created_on, mail_notification) values (?,?,?,?)", 
		group_id, product_id, created_on, mail_notification)
      member_id_of_group = select_last_insert_id()
      self.red_exec_sql("INSERT INTO member_roles (member_id, role_id, inherited_from) values (?,?,?)", 
		member_id_of_group, role_id, 0)
      self.red_exec_sql("INSERT INTO member_roles (member_id, role_id, inherited_from) select members.id, ?, ? FROM members,users where members.project_id = ? and members.user_id = users.id and users.type = ?", 
		role_id, member_id_of_group, product_id, 'User')
    end
  end

  def migrate_groups_users
    self.log("Migrate groups users")
    self.red_select_sql("select distinct (select members.user_id from members where members.id = mr.inherited_from) as group_id, m.user_id FROM member_roles as mr, members as m where mr.inherited_from is not null and mr.inherited_from <> 0 and mr.member_id = m.id") do |row|
      group_id = row["group_id"]
      user_id = row["user_id"]
      self.red_exec_sql("INSERT INTO groups_users (group_id, user_id) values (?, ?)", group_id, user_id)
    end
  end

  def insert_project_trackers(project_id)
    [1,2,3].each do |tracker_id|
      self.red_exec_sql("INSERT INTO projects_trackers (project_id, tracker_id) VALUES (?, ?)", project_id, tracker_id)
    end
  end

  def insert_project_modules(project_id)
    REDMINE_ENABLED_MODULES.each do |m|
      self.red_exec_sql("INSERT INTO enabled_modules (project_id, name) VALUES (?, ?)", project_id, m)
    end
  end

  def perform_sanity_checks
    verify_bug_priorities()
    verify_bug_status()
    verify_bug_severities()
    verify_trackers()
    verify_issue_statuses()
    verify_issue_priorities()
  end

  def make_query_string(strings)
    quoted_strings = strings.collect {|s| s.to_s. sub(/^(.*)$/, '\'\1\'') }
    return "(#{quoted_strings.join(", ")})"
  end

  def verify_bug_priorities
    self.log("checking bug priorities...")
    count = 0
    self.bz_select_sql("select bug_id, priority from bugs where priority not in #{make_query_string(ISSUE_PRIORITIES.keys)}") do |row|
      (bug_id, priority) = row
      self.log "bug #{bug_id}: unknown bug priority #{priority}."
      count += 1
    end
    if count > 0
      throw "there are bug priorities, which cannot be mapped. please modify the ISSUE_PRIORITIES in settings.rb accordingly."
    end
  end

  def verify_bug_status
    self.log("checking bug status...")
    count = 0
    self.bz_select_sql("select bug_id, bug_status from bugs where bug_status not in #{make_query_string(ISSUE_STATUS.keys)}") do |row|
      (bug_id, bug_status) = row
      self.log "bug #{bug_id}: unknown bug status #{bug_status}."
      count += 1
    end
    if count > 0
      throw "there are bug priorities, which cannot be mapped. please modify the ISSUE_STATUS in settings.rb accordingly."
    end
  end

  def verify_bug_status
    self.log("checking bug status...")
    count = 0
    self.bz_select_sql("select bug_id, bug_status from bugs where bug_status not in #{make_query_string(ISSUE_STATUS.keys)}") do |row|
      (bug_id, bug_status) = row
      self.log "bug #{bug_id}: unknown bug status #{bug_status}."
      count += 1
    end
    if count > 0
      throw "there are bug priorities, which cannot be mapped. please modify the ISSUE_STATUS in settings.rb accordingly."
    end
  end

  def verify_bug_severities
    self.log("checking bug status...")
    count = 0
    self.bz_select_sql("select bug_id, bug_severity from bugs where bug_severity not in #{make_query_string(ISSUE_TRACKERS.keys)}") do |row|
      (bug_id, bug_severity) = row
      self.log "bug #{bug_id}: unknown bug severity #{bug_severity}."
      count += 1
    end
    if count > 0
      throw "there are bug priorities, which cannot be mapped. please modify the ISSUE_TRACKERS in settings.rb accordingly."
    end
  end

  def verify_trackers
    ISSUE_TRACKERS.values.uniq.each do |id|
       unless red_check_exists("select id from trackers where id=?", id)
         throw "cannot find tracker in trackers table with id #{id}"
       end
    end
  end

  def verify_issue_statuses
    ISSUE_STATUS.values.uniq.each do |id|
       unless red_check_exists("select id from issue_statuses where id=?", id)
         throw "cannot find status in issue_statuses table with id #{id}"
       end
    end
  end

  def verify_issue_priorities
    ISSUE_PRIORITIES.values.uniq.each do |id|
       unless red_check_exists("select id from enumerations where id=?", id)
         throw "cannot find issue priority in enumerations table with id=#{id}"
       end
    end
  end

end

# --------------------------------------------------------------------------------------------------
# MAIN
begin
  bzred = BugzillaToRedmine.new
  bzred.migrate
rescue => e
  puts e.inspect
  puts e.backtrace
end
