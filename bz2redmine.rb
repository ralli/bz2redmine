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

require "rubygems"
require "mysql"
require "settings"

class ConnectionInfo
  attr_accessor :host
  attr_accessor :user
  attr_accessor :password
  attr_accessor :dbname

  def initialize(host, user, password, dbname)
    @host = host
    @user = user
    @password = password
    @dbname = dbname
  end
end

class BugzillaToRedmine
  def initialize
    @bugzillainfo =  ConnectionInfo.new(BUGZILLA_HOST, BUGZILLA_USER, BUGZILLA_PASSWORD, BUGZILLA_DB)
    @redmineinfo = ConnectionInfo.new(REDMINE_HOST, REDMINE_USER, REDMINE_PASSWORD, REDMINE_DB)

    # Bugzilla priority to Redmine priority map
    @issuePriorities = ISSUE_PRIORITIES

    # Bugzilla severity to Redmine tracker map
    @issueTrackers = ISSUE_TRACKERS

    # Bugzilla status to Redmine status map
    @issueStatus = ISSUE_STATUS 
  end

  def migrate
    self.open_connections
    self.clear_redmine_tables
    self.migrate_projects
    self.migrate_versions
    self.migrate_users
    self.migrate_members
    self.migrate_issues
    self.migrate_issue_relations
    self.migrate_attachments
    self.close_connections
  end

  def open_connections
    @bugzilladb = self.open_connection(@bugzillainfo)
    @redminedb = self.open_connection(@redmineinfo)
  end

  def close_connections
    self.log "closing database connections"
    @bugzilladb.close
    @redminedb.close
  end

  def open_connection(info)
    self.log "opening #{info.inspect}"
    return Mysql::new(info.host, info.user, info.password, info.dbname)
  end

  def clear_redmine_tables
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

  def log(s)
    puts s
  end

  def migrate_projects
    self.bz_select_sql("SELECT products.id, products.name, products.description, products.classification_id, products.disallownew, classifications.name as classification_name FROM products, classifications WHERE products.classification_id = classifications.id") do |row|
      identifier = row[1].downcase
      status = row[3] == 1 ? 9 : 1
      created_at = self.find_min_created_at_for_product(row[0])
      updated_at = self.find_max_bug_when_for_product(row[0])
      self.red_exec_sql("INSERT INTO projects (id, name, description, is_public, identifier, created_on, updated_on, status) values (?, ?, ?, ?, ?, ?, ?, ?)", row[0], row[1], row[2], 1, identifier,
        created_at, updated_at, status)
      self.insert_project_trackers(row[0])
      self.insert_project_modules(row[0])
    end
  end

  def find_min_created_at_for_product(product_id)
    bug_when = '1970-01-01 10:22:25'
    sql = "select min(b.creation_ts) from products p join bugs b on b.product_id = p.id where product_id=?"
    self.bz_select_sql(sql, product_id) do |row|
      bug_when = row[0]
    end
    return bug_when
  end

  def find_max_bug_when_for_product(product_id)
    bug_when = '1970-01-01 10:22:25'
    sql = "select max(l.bug_when) from products p join bugs b on b.product_id = p.id join longdescs l on l.bug_id = b.bug_id where b.product_id=?"
    self.bz_select_sql(sql, product_id) do |row|
      bug_when = row[0]
    end
    return bug_when
  end

  def migrate_versions
    self.red_exec_sql("delete from versions")
    self.bz_select_sql("SELECT id, product_id AS project_id, value AS name FROM versions") do |row|
      self.red_exec_sql("INSERT INTO versions (id, project_id, name) VALUES (?, ?, ?)", row[0], row[1], row[2])
    end
  end

  def migrate_users
    ["DELETE FROM users",
      "DELETE FROM user_preferences",
      "DELETE FROM members",
      "DELETE FROM messages",     
      "DELETE FROM tokens",
      "DELETE FROM watchers"].each do |sql|
      self.red_exec_sql(sql)
    end
    self.bz_select_sql("SELECT userid, login_name, realname, disabledtext FROM profiles") do |row|
      user_id = row[0]
      login_name = row[1]
      real_name = row[2]
      disabled_text = row[3]
      if real_name.nil? 
        (last_name, first_name) = ['bla', 'bla']
      else
        (last_name, first_name) = real_name.split(/[ ,]+/)
        if first_name.to_s.strip.empty?
          first_name = 'bla'
        end
      end
      status = disabled_text.to_s.strip.empty? ? 1 : 3
      self.red_exec_sql("INSERT INTO users (id, login, mail, firstname, lastname, language, mail_notification, status) values (?, ?, ?, ?, ?, ?, ?, ?)",
        user_id, login_name, login_name, first_name, last_name, 'en', 0, status)
      other = """---
:comments_sorting: asc
:no_self_notified: true
      """
      self.red_exec_sql("INSERT INTO user_preferences (user_id,others) values (?, ?)", user_id, other)
    end
  end

  def find_version_id(project_id, version)
    result = -1
    self.red_select_sql("select id from versions where project_id=? and name=?", project_id, version) do |row|
      result = row[0]
    end
    return result
  end

  def find_max_bug_when(bug_id)
    bug_when = '1970-01-01 10:22:25'
    self.bz_select_sql("select max(bug_when) from longdescs where bug_id=?", bug_id) do |row|
      bug_when = row[0]
    end
    return bug_when
  end

 

  def migrate_issues
    self.red_exec_sql("delete from issues")
    self.red_exec_sql("delete from journals")
    sql = "SELECT bugs.bug_id,
		       bugs.assigned_to,
		       bugs.bug_status,
		       bugs.creation_ts,
		       bugs.short_desc,
		       bugs.product_id,
		       bugs.reporter,
		       bugs.version,
		       bugs.resolution,
		       bugs.estimated_time,
		       bugs.remaining_time,
		       bugs.deadline,
		       bugs.bug_severity,
		       bugs.priority,
		       bugs.component_id,
		       bugs.status_whiteboard AS whiteboard,
		       bugs.bug_file_loc AS url,
		       longdescs.comment_id,
		       longdescs.thetext,
		       longdescs.bug_when,
		       longdescs.who,
		       longdescs.isprivate
		   FROM bugs, longdescs
		   WHERE bugs.bug_id = longdescs.bug_id
		   ORDER BY bugs.creation_ts, longdescs.bug_when"
    current_bug_id = -1
    self.bz_select_sql(sql) do |row|
      ( bug_id,
        assigned_to,
        bug_status,
        creation_ts,
        short_desc,
        product_id,
        reporter,
        version,
        resolution,
        estimated_time,
        remaining_time,
        deadline,
        bug_severity,
        priority,
        component_id,
        whiteboard,
        url,
        comment_id,
        thetext,
        bug_when,
        who,
        isprivate) = row
      if(current_bug_id != bug_id)
        sql = "INSERT INTO issues (id, project_id, subject, description, assigned_to_id, author_id, created_on, updated_on, start_date, estimated_hours, due_date, priority_id, fixed_version_id, category_id, tracker_id, status_id) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        status_id = 1
        version_id = self.find_version_id(product_id, version)
        updated_at = self.find_max_bug_when(bug_id)
        priority_id = @issuePriorities[priority]
        tracker_id = @issueTrackers[bug_severity]
        status_id = @issueStatus[bug_status]
        self.red_exec_sql(sql, bug_id, product_id, short_desc, thetext, assigned_to, reporter, creation_ts,  updated_at, creation_ts, estimated_time, '', priority_id, version_id, component_id, tracker_id,  status_id)
        current_bug_id = bug_id
      else
        sql = "INSERT INTO journals (id, journalized_id, journalized_type, user_id, notes, created_on)  VALUES (?, ?, ?, ?, ?, ?)"
        self.red_exec_sql(sql, comment_id, bug_id, "Issue", who, thetext, bug_when)
      end
    end
  end

  def migrate_issue_relations
    self.red_exec_sql("delete from issue_relations")
    sql = "SELECT blocked, dependson FROM dependencies"
    self.bz_select_sql(sql) do |row|
      self.red_exec_sql("INSERT INTO issue_relations (issue_from_id, issue_to_id, relation_type) values (?, ?, ?)", row[0], row[1], "blocks")
    end

    sql = "SELECT dupe_of, dupe FROM duplicates"
    self.bz_select_sql(sql) do |row|
      self.red_exec_sql("INSERT INTO issue_relations (issue_from_id, issue_to_id, relation_type) values (?, ?, ?)", row[0], row[1], "duplicates")
    end
  end

  def migrate_attachments
    self.red_exec_sql("DELETE FROM attachments")
    sql = "SELECT attachments.attach_id, attachments.bug_id, attachments.filename, attachments.mimetype, attachments.submitter_id, attachments.creation_ts, attachments.description, attach_data.thedata FROM attachments, attach_data WHERE attachments.attach_id = attach_data.id"
    self.bz_select_sql(sql) do |row|
      (attach_id, bug_id, filename, mimetype, submitter_id, creation_ts, description, thedata ) = row
      disk_filename = self.get_disk_filename(attach_id, filename)
      filesize = thedata.size()
      sql = "INSERT INTO attachments (id, container_id, container_type, filename, filesize, disk_filename, content_type, digest, downloads, author_id, created_on, description) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
      self.red_exec_sql(sql, attach_id, bug_id, 'Issue', filename, filesize, disk_filename, mimetype, '', 0, submitter_id, creation_ts, description)
      File.open("#{ATTACHMENT_PATH}/#{disk_filename}", "w") do |f|
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
    self.log("*** migrate members ***")
    self.bz_select_sql("SELECT DISTINCT user_group_map.user_id, group_control_map.product_id AS project_id FROM group_control_map, user_group_map WHERE group_control_map.group_id = user_group_map.group_id") do |row|
      user_id = row[0]
      product_id = row[1]
      role_id = '6'
      created_on = "2007-01-01 12:00:00"
      mail_notification = 0
      self.red_exec_sql("INSERT INTO members (user_id, project_id, role_id, created_on, mail_notification)", user_id, product_id, role_id, created_on, mail_notification)
    end
  end

  def insert_project_trackers(project_id)
    [1,2,4].each do |tracker_id|
      self.red_exec_sql("INSERT INTO projects_trackers (project_id, tracker_id) VALUES (?, ?)", project_id, tracker_id)
    end
  end

  def insert_project_modules(project_id)
    ['issue_tracking',
      'time_tracking',
      'news',
      'documents',
      'files',
      'wiki',
      'repository',
      'boards',].each do |m|
      self.red_exec_sql("INSERT INTO enabled_modules (project_id, name) VALUES (?, ?)", project_id, m)
    end
  end

  def bz_exec_sql(sql)
    self.log("bugzilla: #{sql}")
  end

  def bz_select_sql(sql, *args, &block)
    self.log("bugzilla: #{sql} args=#{args.join(',')}")
    statement = @bugzilladb.prepare(sql)
    statement.execute(*args)
    while row = statement.fetch do
      yield row
    end
    statement.close()
  end

  def red_exec_sql(sql, *args)
    self.log("redmine: #{sql} args=#{args.join(',')}")
    statement = @redminedb.prepare(sql)
    statement.execute(*args)
    statement.close()
  end

  def red_select_sql(sql, *args, &block)
    self.log("redmine: #{sql} args=#{args.join(',')}")
    statement = @redminedb.prepare(sql)
    statement.execute(*args)
    while row = statement.fetch do
      yield row
    end
    statement.close()
  end
end

begin
  bzred = BugzillaToRedmine.new
  bzred.migrate
rescue => e
  puts e.inspect
  puts e.backtrace
end
