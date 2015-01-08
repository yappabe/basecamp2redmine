#!/usr/bin/env ruby

# Ruby script to extract data from a Basecamp "backup" XML file and import into Redmine.
#
#
# You must install the Nokogiri gem, which is an XML parser: sudo gem install nokogiri
#
# This script is a "code generator", in that it writes a new Ruby script to STDOUT.
# This script contains invocations of Redmine's ActiveRecord models.  The resulting
# "import script" can be edited before being executed, if desired.
#
# Before running this script, you must create a Tracker inside Redmine called "Basecamp Todo".
# You do not need to associate it with any existing projects.
#
#
# DATABASE CORRECTION .sql files
# Also, you may need to temporarily delete the following unique index on a join table
# ALTER TABLE `projects_trackers` DROP INDEX `projects_trackers_unique`;
#
# Once you're finished with this import, you can get your unique values/keys with the following SQL statements
# CREATE TABLE `projects_trackers_distinct` SELECT distinct * FROM `projects_trackers`;
# TRUNCATE TABLE `projects_trackers`;
# ALTER TABLE `projects_trackers` ADD UNIQUE KEY `projects_trackers_unique` (`project_id`,`tracker_id`);
# INSERT INTO `projects_trackers` SELECT * FROM `projects_trackers_distinct`;
# DROP TABLE `projects_trackers_distinct`
#
#
# This script, if saved as filename basecamp2redmine.rb, can be invoked as follows.
# This will generate an ActiveRecord-based import script in the current directory,
# which should be the root directory of the Redmine installation.
#
# ruby basecamp2redmine.rb my-basecamp-backup.xml > basecamp-import.rb
# script/runner -e development basecamp-import.rb
#
# The import process can be reversed by running:
#
# ruby basecamp2redmine_undo.rb my-basecamp-backup.xml > basecamp-undo.rb
# script/runner -e development basecamp-undo.rb
#
# Author: Joeri Verdeyen <joeriv@yappa.be>
#
# CHANGELOG
# 2010-08-23 Initial public release
# 2010-11-21 Applied bugfix to properly escape quotes
# 2011-08-05 Added methods MyString.clean() and MyString.cleanHtml() to do more string escaping (quotes, interprited special characters, etc) [alan]
# 2011-08-05 Added logical controls for excluding various IDs from import, cleaned up the string cleanup functions, and added before/after SQL files [alan]
# 2011-09-08 Implemented better controls for inclusion/exclusion, Improved checking for existing Item before creation, Pulling in Firm as a Client [alan]
# 2014-01-07 Improvements: user mapping, todo comments (journals)
#
#
# See MIT License below.  You are not required to provide the author with changes
# you make to this software, but it would be appreciated, as a courtesy, if it is possible.
#
# LEGAL NOTE:
# The Basecamp name is a registered trademark of 37 Signals, LLC.  Use of this trademark
# is for reference only, and does not imply any relationship or affiliation with or endorsement
# from or by 37 Signals, LLC.
# Ted Behling, the author of this script, has no affiliation with 37 Signals, LLC.
# All source code contained in this file is the original work of Ted Behling.
# Product names, logos, brands, and other trademarks featured or referred to within
# this software are the property of their respective trademark holders.
# 37 Signals does not sponsor or endorse this script or its author.
#
# DHH, please don't sue me for trademark infringement.  I don't have anything you'd want anyway.
#

require 'rubygems'
require 'nokogiri'

# These lengths came from the result of "cd redmine/app/models; grep 'validates_length_of' project.rb issue.rb message.rb board.rb"
PROJECT_NAME_LENGTH = 30
BOARD_DESCRIPTION_LENGTH = 255
MESSAGE_SUBJECT_LENGTH = 255
ISSUE_SUBJECT_LENGTH = 255
MEETING_SUBJECT_LENGTH = 255


ELLIPSIS = '...'
DEFAULT_TRACKER = 'Bug'
TODO_LIST_TRACKER = 'Todo List'
NAME_APPEND = ''

# Include only a few specific Items by ID
# keep empty if you want to include all (works in combination with EXCLUDE)
INCLUDE_ONLY_CLIENT_IDS = [] # eg: [ "1234" , "1235" ]

# Exclude a few specific Posts by ID
# keep empty if you want to include all (works in combination with INCLUDE_ONLY)
ON_FAILURE_DELETE = false
EXCLUDE_CLIENT_IDS = [] # eg: [ "1234" , "1235" ]
exclude_projects = Array.new
exclude_parent_todo = Array.new
journals_list = Array.new
BASECAMP_PARENT_PROJECT_ID = 0 # nil
BASECAMP_COMPANY_NAME_AS_PARENT_PROJECT = false
BASECAMP_COMPANY_NAME_PROJECT_PREFIX = ""
BASECAMP_COMPANY_NAME_PROJECT_PREFIX_SHORT = ""

users_map = {
  # "11357920" => 5
}

filename = ARGV[0] or raise ArgumentError, "Must have filename specified on command line"

# Hack Nokogiri to escape our curly braces for us
# This script delimits strings with curly braces so it's a little easier to think about quoting in our generated code
module Nokogiri
  module XML
    class Node
      alias :my_original_content :content
      def content(*args)
        # Escape { and } with \
        my_original_content(*args).gsub(/\{|\}/, '\\\\\0')
      end
    end
  end
end

# Create several instance methods in String to handle multibyte strings,
# using the Unicode support built into Ruby's regex library
class MyString < String
  # Get the first several *characters* from a string, respecting Unicode
  def my_left(chars)
    raise ArgumentError 'arg must be a number' unless chars.is_a? Numeric
    self.match(/^.{0,#{chars}}/u).to_s
  end
  # Get the last several *characters* from a string, respecting Unicode
  def my_right(chars)
    raise ArgumentError 'arg must be a number' unless chars.is_a? Numeric
    self.match(/.{0,#{chars}}$/u).to_s
  end
  def my_size
    self.gsub(/./u, '.').size
  end
  # Truncate a string from both sides, with an ellipsis in the middle
  # This makes sense for this app, since names are often something like "Project 1, Issue XYZ" and "Project 1, Issue ABC";
  # names are significant at the beginning and end of the string
  def center_truncate(length, ellipsis = '...')
    ellipsis = MyString.new(ellipsis)
    if self.my_size <= length
      return self
    else
      left = self.my_left((length / 2.0).ceil - (ellipsis.my_size / 2.0).floor )
      right = self.my_right((length / 2.0).floor - (ellipsis.my_size / 2.0).ceil )
      return MyString.new(left + ellipsis + right)
    end
  end
  # Escape Other Charcters which have given me problems - <alan+basecamp2redmine@zeroasterisk.com> - 2011.08.04
  def clean()
    string = self
    return MyString.new(string.gsub(/\"/, '').gsub('\\C', '\\\\\\\\C').gsub('\\M', '\\\\\\\\M').gsub('s\\x', 's\\\\\\\\x').strip)
  end
  # Escape Other Charcters which have given me problems - <alan+basecamp2redmine@zeroasterisk.com> - 2011.08.04
  def cleanHTML()
    string = self
    string = string.gsub(/&lt;/, '<').gsub(/&gt;/, '>').gsub(/&amp;/, '&')
    string = string.gsub(/<div[^>]*>/, '').gsub(/<\/div>/, "\n").gsub(/<br ?\/?>/, "\n")
    return MyString.new(string.strip);
  end
end

src = []
src << %{projects = {}}
src << %{todo_lists = {}} # Todo lists are actually tasks that have sub-tasks --- was sub-projects
src << %{todos = {}}
src << %{journals = {}}
src << %{messages = {}}
src << %{comments = {}}
src << %{meetings = {}}

src << %{BASECAMP_TRACKER = Tracker.find_by_name '#{DEFAULT_TRACKER}'}
src << %{TODO_LIST_TRACKER = Tracker.find_by_name '#{TODO_LIST_TRACKER}'}
src << %{raise "Tracker named '#{DEFAULT_TRACKER}' must exist" unless BASECAMP_TRACKER}
src << %{raise "Tracker named '#{TODO_LIST_TRACKER}' must exist" unless TODO_LIST_TRACKER}

src << %{DEFAULT_STATUS = IssueStatus.default}
src << %{CLOSED_STATUS = IssueStatus.find :first, :conditions => { :is_closed => true }}
src << %{AUTHOR = User.anonymous  #User.find 1}

src << %{begin}

x = Nokogiri::XML(File.read filename)

# String extensions
String.class_eval do

  def to_slug
    self.transliterate.downcase.gsub(/[^a-z0-9 ]/, ' ').strip.gsub(/[ ]+/, '-')
  end

  # differs from the 'to_slug' method in that it leaves in the dot '.' character and removes Windows' crust from paths (removes "C:\Temp\" from "C:\Temp\mieczyslaw.jpg")
  def sanitize_as_filename
    self.gsub(/^.*(\\|\/)/, '').transliterate.downcase.gsub(/[^a-z0-9\. ]/, ' ').strip.gsub(/[ ]+/, '-')
  end

  def transliterate
    # Unidecode gem is missing some hyphen transliterations
    self.gsub(/[-‐‒–—―⁃−­]/, '-')
  end

end

if (BASECAMP_COMPANY_NAME_AS_PARENT_PROJECT)
  x.xpath('//firm').each do |project|
    name = MyString.new((project % 'name').content).clean()
    short_name = MyString.new(BASECAMP_COMPANY_NAME_PROJECT_PREFIX_SHORT + name).center_truncate(PROJECT_NAME_LENGTH - NAME_APPEND.size, ELLIPSIS).clean()
    short_board_description = MyString.new(BASECAMP_COMPANY_NAME_PROJECT_PREFIX + name).my_left(BOARD_DESCRIPTION_LENGTH).clean()
    id = (project % 'id').content
    goodclient = ((INCLUDE_ONLY_CLIENT_IDS.empty? || INCLUDE_ONLY_CLIENT_IDS.include?(id)) && !EXCLUDE_CLIENT_IDS.include?(id))
    if (goodclient)
      src << %{puts " About to create firm as parent project #{id} ('#{short_name}')."}
      src << %{  projects['#{id}'] = Project.find_by_name %{#{short_name}}}
      src << %{  if  projects['#{id}'] == nil}
      src << %{    projects['#{id}'] = Project.new(:name => %{#{short_name}}, :description => %{#{name}}, :identifier => "#{short_name.to_s.to_slug}")}
      src << %{    projects['#{id}'].enabled_module_names = ['issue_tracking', 'boards']}
      src << %{    projects['#{id}'].trackers << BASECAMP_TRACKER}
      src << %{    projects['#{id}'].boards << Board.new(:name => %{#{short_name}#{NAME_APPEND}}, :description => %{#{short_board_description}})}
      src << %{    projects['#{id}'].save!}
      if (BASECAMP_PARENT_PROJECT_ID>0)
        src << %{    projects['#{id}'].set_parent!(#{BASECAMP_PARENT_PROJECT_ID})}
      end
      src << %{    puts " Saved as New Project ID " + projects['#{id}'].id.to_s}
      src << %{  else}
      src << %{    puts " Exists as Project ID " + projects['#{id}'].id.to_s}
      src << %{    if (projects['#{id}'].boards.empty?)}
      src << %{      puts " (re-creating boards) "}
      src << %{      projects['#{id}'].boards << Board.new(:name => %{#{short_name}#{NAME_APPEND}}, :description => %{#{short_board_description}})}
      src << %{      projects['#{id}'].save!}
      src << %{    end}
      src << %{  end}
      # TODO add members to project with roles
      # Member.create(:user => u, :project => @target_project, :roles => [role])
    else
      src << %{# Skipping client as parent project #{id} ('#{short_name}').}
    end
  end
  x.xpath('//clients/client').each do |project|
    name = MyString.new((project % 'name').content).clean()
    short_name = MyString.new(BASECAMP_COMPANY_NAME_PROJECT_PREFIX_SHORT + name).center_truncate(PROJECT_NAME_LENGTH - NAME_APPEND.size, ELLIPSIS).clean()
    short_board_description = MyString.new(BASECAMP_COMPANY_NAME_PROJECT_PREFIX + name).my_left(BOARD_DESCRIPTION_LENGTH).clean()
    id = (project % 'id').content
    goodclient = ((INCLUDE_ONLY_CLIENT_IDS.empty? || INCLUDE_ONLY_CLIENT_IDS.include?(id)) && !EXCLUDE_CLIENT_IDS.include?(id))
    if (goodclient)
      src << %{puts " About to create client as parent project #{id} ('#{short_name}')."}
      src << %{  projects['#{id}'] = Project.find_by_name %{#{short_name}}}
      src << %{  if  projects['#{id}'] == nil}
      src << %{    projects['#{id}'] = Project.new(:name => %{#{short_name}}, :description => %{#{name}}, :identifier => "#{short_name.to_s.to_slug}")}
      src << %{    projects['#{id}'].enabled_module_names = ['issue_tracking', 'boards']}
      src << %{    projects['#{id}'].trackers << BASECAMP_TRACKER}
      src << %{    projects['#{id}'].boards << Board.new(:name => %{#{short_name}#{NAME_APPEND}}, :description => %{#{short_board_description}})}
      src << %{    projects['#{id}'].save!}
      if (BASECAMP_PARENT_PROJECT_ID>0)
        src << %{    projects['#{id}'].set_parent!(#{BASECAMP_PARENT_PROJECT_ID})}
      end
      src << %{    puts " Saved as New Project ID " + projects['#{id}'].id.to_s}
      src << %{  else}
      src << %{    puts " Exists as Project ID " + projects['#{id}'].id.to_s}
      src << %{    if (projects['#{id}'].boards.empty?)}
      src << %{      puts " (re-creating boards) "}
      src << %{      projects['#{id}'].boards << Board.new(:name => %{#{short_name}#{NAME_APPEND}}, :description => %{#{short_board_description}})}
      src << %{      projects['#{id}'].save!}
      src << %{    end}
      src << %{  end}
      # TODO add members to project with roles
      # Member.create(:user => u, :project => @target_project, :roles => [role])
    else
      src << %{# Skipping client as parent project #{id} ('#{short_name}').}
    end
  end
end

x.xpath('//project').each do |project|
  project_name = MyString.new((project % 'name').content).clean()
  project_short_name = MyString.new(project_name).center_truncate(PROJECT_NAME_LENGTH - NAME_APPEND.size, ELLIPSIS).clean()
  project_short_board_description = MyString.new(project_name).my_left(BOARD_DESCRIPTION_LENGTH).clean()
  project_id = (project % 'id').content
  project_archived = (project % 'status').content == 'archived'
  project_company_id = BASECAMP_PARENT_PROJECT_ID

  if (project_archived)
    exclude_projects.push(project_id.to_s)
    src << %{# Skipping archived project #{project_id} ('#{project_short_name}').}

  else

    # puts "Reading #{project_short_name}"

    src << %{puts " About to create project #{project_id} ('#{project_short_name}')."}
    src << %{  projects['#{project_id}'] = Project.find_by_name %{#{project_short_name}}}
    src << %{  if  projects['#{project_id}'] == nil}
    src << %{    projects['#{project_id}'] = Project.new(:name => %{#{project_short_name}}, :description => %{#{project_name}}, :identifier => "#{project_short_name.to_s.to_slug}")}
    src << %{    projects['#{project_id}'].enabled_module_names = ['issue_tracking', 'boards']}
    src << %{    projects['#{project_id}'].trackers << BASECAMP_TRACKER}
    src << %{    projects['#{project_id}'].trackers << TODO_LIST_TRACKER}
    src << %{    projects['#{project_id}'].boards << Board.new(:name => %{#{project_short_name}#{NAME_APPEND}}, :description => %{#{project_short_board_description}})}

    if (project_company_id>0)
      src << %{    projects['#{project_id}'].set_parent!(projects['#{project_company_id}'].id)}
    end

    src << %{    projects['#{project_id}'].save!}
    src << %{    puts " Saved as New Project ID " + projects['#{project_id}'].id.to_s}


    src << %{  else}
    src << %{    puts " Exists as Project ID " + projects['#{project_id}'].id.to_s}
    src << %{    if (projects['#{project_id}'].boards.empty?)}
    src << %{        puts " (re-creating boards) "}
    src << %{      projects['#{project_id}'].boards << Board.new(:name => %{#{project_short_name}#{NAME_APPEND}}, :description => %{#{project_short_board_description}})}
    src << %{      projects['#{project_id}'].save!}
    src << %{    end}
    src << %{  end}

    # TODO add members to project with roles
    # Member.create(:user => u, :project => @target_project, :roles => [role])



    project.xpath('.//post').each do |post|
      post_body = MyString.new((post % 'body').content).clean().cleanHTML()
      post_message_reply_prefix = 'Re: '
      post_title = MyString.new((post % 'title').content).clean().cleanHTML()
      post_short_title = MyString.new(post_title).center_truncate(MESSAGE_SUBJECT_LENGTH - post_message_reply_prefix.size, ELLIPSIS)
      post_id = (post % 'id').content
      post_parent_project_id = (post % 'project-id').content
      post_author_name = MyString.new((post % 'author-name').content).clean()
      post_author_id = users_map[(post % 'author-id').content] rescue 'AUTHOR'
      post_posted_on = (post % 'posted-on').content

      # puts "Reading #{project_short_name}- #{post_short_title}"

      src << %{puts " About to create post #{post_id} as Redmine message under project #{post_parent_project_id}."}
      src << %{  messages['#{post_id}'] = Message.find(:first, :include => [:board], :conditions => { :subject => %{#{post_short_title}}, :boards => { :id => projects['#{post_parent_project_id}'].boards.first.id } } ) }
      src << %{  if  messages['#{post_id}'] == nil}
      src << %{    messages['#{post_id}'] = Message.new :board => projects['#{post_parent_project_id}'].boards.first,
      :subject => %{#{post_short_title}}, :content => %{#{post_body}\\n\\n-- \\n#{post_author_name}},
      :created_on => '#{post_posted_on}' }

      if ( post_author_id.to_s == 'AUTHOR' || post_author_id.to_s == '')
        src << %{    messages['#{post_id}'].author_id = AUTHOR.id}
      else
        src << %{    messages['#{post_id}'].author_id = #{post_author_id}}
      end

      #:completed_at => '#{completed_at}'
      #src << %{    messages['#{post_id}'].author = AUTHOR}
      src << %{    messages['#{post_id}'].save!}
      src << %{    puts " Saved as Message ID " + messages['#{post_id}'].id.to_s}
      src << %{  else}
      src << %{    puts " Exists as Message ID " + messages['#{post_id}'].id.to_s}
      src << %{  end}

      # Nested comments
      post.xpath('.//comment[commentable-type = "Post"]').each do |comment|
        comment_body = MyString.new((comment % 'body').content).clean().cleanHTML()
        comment_id = (comment % 'id').content
        parent_message_id = (comment % 'commentable-id').content
        comment_author_name = MyString.new((comment % 'author-name').content).clean()
        comment_created_at = (comment % 'created-at').content
        comment_author_id = users_map[(comment % 'author-id').content] rescue 'AUTHOR'

        # puts "Reading #{project_short_name}- Post: #{post_short_title} - comment #{comment_id}"

        src << %{puts " About to create post comment #{comment_id} as Redmine sub-message under " + messages['#{post_id}'].id.to_s + " project #{post_parent_project_id}."}
        src << %{  comments['#{post_id}'] = Message.find(:first, :include => [:board], :conditions => { :subject => %{#{post_message_reply_prefix}#{post_short_title}}, :parent_id => messages['#{post_id}'].id, :created_on => %{#{comment_created_at}}, :boards => { :project_id => projects['#{post_parent_project_id}'].id } } ) }
        src << %{  if  comments['#{post_id}'] == nil}
        src << %{    comments['#{comment_id}'] = Message.new(:board => projects['#{post_parent_project_id}'].boards.first,
        :subject => %{#{post_message_reply_prefix}#{post_short_title}}, :content => %{#{comment_body}\\n\\n-- \\n#{comment_author_name}},
        :created_on => '#{comment_created_at}', :parent => messages['#{post_id}'] )}

        if ( comment_author_id.to_s == 'AUTHOR' || comment_author_id.to_s == '')
          src << %{    comments['#{comment_id}'].author_id = AUTHOR.id}
        else
          src << %{    comments['#{comment_id}'].author_id = #{comment_author_id}}
        end

        src << %{    comments['#{comment_id}'].save!}
        src << %{    puts " Saved comment as Message ID " + comments['#{comment_id}'].id.to_s}
        src << %{  else}
        src << %{    puts " Exists comment as Message ID " + comments['#{post_id}'].id.to_s}
        src << %{  end}
      end
    end



    project.xpath('.//todo-list').each do |todo_list|
      todo_list_name = MyString.new((todo_list % 'name').content).clean()
      todo_list_short_name = MyString.new(todo_list_name).center_truncate(ISSUE_SUBJECT_LENGTH, ELLIPSIS).clean()
      todo_list_id = (todo_list % 'id').content
      todo_list_description = MyString.new((todo_list % 'description').content).clean()
      todo_list_parent_project_id = (todo_list % 'project-id').content
      todo_list_complete = (todo_list % 'complete').content == 'true'
      todo_list_author_id = users_map[(todo_list % 'creator-id').content] rescue 'AUTHOR'

      # puts "Reading #{project_short_name} Todo list: #{todo_list_id}"

      src << %{puts " About to create todo-list #{todo_list_id} ('#{todo_list_short_name}') as Redmine issue under project #{todo_list_parent_project_id}."}
      src << %{  todo_lists['#{todo_list_id}'] = Issue.find(:first, :conditions => { :subject => %{#{todo_list_short_name}}, :project_id => projects['#{todo_list_parent_project_id}'].id }) }
      src << %{  if  todo_lists['#{todo_list_id}'] == nil}
      src << %{    todo_lists['#{todo_list_id}'] = Issue.new(:subject => %{#{todo_list_short_name}}, :description => %{#{todo_list_description} })}
      #:created_on => bug.date_submitted,
      #:updated_on => bug.last_updated
      #i.author = User.find_by_id(users_map[bug.reporter_id])
      #i.category = IssueCategory.find_by_project_id_and_name(i.project_id, bug.category[0,30]) unless bug.category.blank?
      src << %{    todo_lists['#{todo_list_id}'].status = #{todo_list_complete} ? CLOSED_STATUS : DEFAULT_STATUS}
      src << %{    todo_lists['#{todo_list_id}'].tracker = TODO_LIST_TRACKER}


      if ( todo_list_author_id == 'AUTHOR' || todo_list_author_id.to_s == '')
        src << %{    todo_lists['#{todo_list_id}'].author = AUTHOR}
      else
        src << %{    todo_lists['#{todo_list_id}'].author = User.find_by_id(#{todo_list_author_id})}
      end

      src << %{    todo_lists['#{todo_list_id}'].project = projects['#{todo_list_parent_project_id}']}
      src << %{    todo_lists['#{todo_list_id}'].save!}
      src << %{    puts " Saved as New Issue ID " + todo_lists['#{todo_list_id}'].id.to_s}
      src << %{  else}
      src << %{    puts " Exists as Issue ID " + todo_lists['#{todo_list_id}'].id.to_s}
      src << %{  end}

      todo_list.xpath('.//todo-item').each do |todo_item|
        todo_item_content = MyString.new((todo_item % 'content').content).clean()
        todo_item_short_content = MyString.new(todo_item_content).center_truncate(ISSUE_SUBJECT_LENGTH, ELLIPSIS).clean()
        todo_item_id = (todo_item % 'id').content
        todo_item_parent_todo_list_id = (todo_item % 'todo-list-id').content
        todo_item_complete = (todo_item % 'completed').content == 'true'
        todo_item_created_at = (todo_item % 'created-at').content
        todo_item_nb_of_comments = (todo_item % 'comments-count').content.to_s
        todo_item_assigned_to_id = users_map[(todo_item % 'responsible-party-id').content] rescue 'AUTHOR'
        todo_item_author_id = users_map[(todo_item % 'creator-id').content] rescue 'AUTHOR'
        todo_item_creator_name = MyString.new((todo_list % 'creator-name').content).clean()

        #completed_at = (todo_item % 'completed-at').content rescue nil

        # puts "Reading #{project_short_name} Todo list: #{todo_list_name}"

        src << %{puts " About to create todo #{todo_item_id} as Redmine sub-issue under issue #{todo_item_parent_todo_list_id}."}
        src << %{  todos['#{todo_item_id}'] = Issue.find(:first, :conditions => { :subject => %{#{todo_item_short_content}}, :parent_id => todo_lists['#{todo_item_parent_todo_list_id}'].id }) }
        src << %{  if  todos['#{todo_item_id}'] == nil}
        src << %{    todos['#{todo_item_id}'] = Issue.new :subject => %{#{todo_item_short_content}}, :description => %{#{todo_item_content} \\n\\n-- \\n#{todo_item_creator_name} }, :created_on => '#{todo_item_created_at}' }
        #:completed_at => '#{completed_at}'
        #i.category = IssueCategory.find_by_project_id_and_name(i.project_id, bug.category[0,30]) unless bug.category.blank?
        src << %{    todos['#{todo_item_id}'].status = #{todo_item_complete} ? CLOSED_STATUS : DEFAULT_STATUS}
        src << %{    todos['#{todo_item_id}'].tracker = BASECAMP_TRACKER}

        if ( todo_item_author_id == 'AUTHOR' || todo_item_author_id.to_s == '')
          src << %{    todos['#{todo_item_id}'].author = AUTHOR}
        else
          src << %{    todos['#{todo_item_id}'].author = User.find_by_id(#{todo_item_author_id})}
        end

        if ( todo_item_assigned_to_id.to_s == 'AUTHOR' || todo_item_assigned_to_id.to_s == '')
          src << %{    todos['#{todo_item_id}'].assigned_to_id = AUTHOR.id}
        else
          src << %{    todos['#{todo_item_id}'].assigned_to_id = #{todo_item_assigned_to_id}}
        end

        src << %{    todos['#{todo_item_id}'].project = todo_lists['#{todo_item_parent_todo_list_id}'].project}
        src << %{    todos['#{todo_item_id}'].parent_issue_id = todo_lists['#{todo_item_parent_todo_list_id}'].id}
        src << %{    todos['#{todo_item_id}'].save!}
        # src << %{    puts " Saved as Issue ID " + todos['#{todo_item_id}'].id.to_s}
        src << %{  else}
        # src << %{    puts " Exists as Issue ID " + todos['#{todo_item_id}'].id.to_s}
        src << %{  end}


        if (todo_item_nb_of_comments != "0")

          todo_item.xpath('.//comment[commentable-type = "TodoItem"]').each do |comment|

            journal_body = MyString.new((comment % 'body').content).cleanHTML()
            journal_id = (comment % 'id').content
            parent_todo_id = (comment % 'commentable-id').content
            journal_author_name = MyString.new((comment % 'author-name').content).clean()
            journal_created_at = (comment % 'created-at').content
            journal_author_id = users_map[(comment % 'author-id').content] rescue 'AUTHOR'

            # puts "Reading #{project_short_name} Todo list: #{todo_list_id} Todo Item: #{todo_item_id} Comment: #{journal_id}"

            if(journals_list.include? journal_id)
              puts "Seen #{journal_id} once before"
            end

            src << %{puts " About to create todo journal item #{journal_id} as Redmine journal under project #{todo_item_parent_todo_list_id}."}
            src << %{ j = Journal.new :journalized_type => %{Issue}, :journalized_id => todos['#{todo_item_id}'].id, :notes => %{#{journal_body} \\n\\n-- \\n#{journal_author_name} }, :created_on => %{#{journal_created_at}}}

            if ( journal_author_id == 'AUTHOR' || journal_author_id.to_s == '' )
              src << %{    j.user_id = AUTHOR.id}
            else
              src << %{    j.user_id = #{journal_author_id}}
            end
            src << %{ j.save! }
            # src << %{    journals['#{journal_id}'] = Journal.new(:board => projects['#{parent_project_id}'].boards.first,
            # :subject => %{#{message_reply_prefix}#{short_title}}, :content => %{#{comment_body}\\n\\n-- \\n#{comment_author_name}},
            # :created_on => '#{comment_created_at}', :author => AUTHOR, :parent => messages['#{id}'] )}

            # src << %{    comments['#{comment_id}'].save!}
            src << %{    puts " Saved journal as Journal ID " + j.id.to_s}
            journals_list.push(journal_id)

            # puts journals_list.length
          end
        end
      end
    end

  end
end



src << %{puts "\\n\\n-----------\\nUndo Script\\n-----------\\nTo undo this import, run script/console and paste in this Ruby code.  This will delete only the projects created by the import process.\\n\\n"}

src << %{rescue => e}
src << %{  file = e.backtrace.grep /\#{File.basename(__FILE__)}/}
src << %{  puts "\\n\\nException was raised at \#{file}." }

if (ON_FAILURE_DELETE)
    #src << %{  puts "\\nDeleting all referenced projects!" }
    # don't actually need to delete all the objects individually; deleting the project will cascade deletes
    src << %{puts '[' + projects.values.map(&:id).map(&:to_s).join(',') + '].each   { |i| Project.destroy i }'}
    src << %{  projects.each_value do |p| p.destroy unless p.new_record?; end }
    # More verbose BUT more clear...
    #src << %{puts journals.values.map{|p| "Journal.destroy " + p.id.to_s}.join("; ")}
    #src << %{puts todos.values.map{|p| "Issue.destroy " + p.id.to_s}.join("; ")}
    #src << %{puts todo_lists.values.map{|p| "Issue.destroy " + p.id.to_s}.join("; ")}
    #src << %{puts projects.values.map{|p| "Project.destroy " + p.id.to_s}.join("; ")}
end


src << %{  raise e}
src << %{end}


puts src.join "\n"

__END__

-------
Nokogiri usage note:
doc.xpath('//h3/a[@class="l"]').each do |link|
 puts link.content
end
-------

The MIT License

Copyright (c) 2010 Ted Behling

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.