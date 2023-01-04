# only road test task in test environment
if ENV['RACK_ENV'] == 'test'
  require "minitest/test_task"
  Minitest::TestTask.create(:spec) do |t|
    t.libs << "lib"
    t.libs << "spec"
    t.warning = false
    t.test_globs = ["spec/**/*_spec.rb"]
  end

  task :default => :spec
end

# load environment files if running locally
if ENV['RACK_ENV'] == 'test' || ENV['RACK_ENV'] == 'development'
  require 'dotenv'
  Dotenv.load(
    File.expand_path("../.env.#{ENV['RACK_ENV']}", __FILE__),
    File.expand_path('../.env', __FILE__),)
end

namespace :heroku do
  desc "run tasks on application release"
  task :release do
    `bundle exec rake db:migrate[#{ENV['DATABASE_URL']}]`
    `bundle exec rake db:migrate[#{ENV['FAT_BOY_DATABASE_URL']}]`
  end

  desc "invalidate FE cache for global stats"
  task :invalidate_global_stats_cache do
    url = ENV['FE_GLOBAL_STATS_CACHE_REVALIDATION_URL']

    `curl -s #{url}` unless url.nil?
  end
end

# NOTE: if i do need to re-calculate the previous days stats,
# do that at some random off-time (4 or 5am)
namespace :compute do
  # ex: rake compute:all_daily['2022-07-20']
  desc "compute all daily stats for date"
  task :all_daily, [:date] do |task, args|
    require './lib/main'

    date = args[:date] || (Date.today - 1).to_s
    previous_date = (Date.parse(date) - 1).to_s

    # process all user activities for given date
    Jobs::ProcessUserActivities.perform_async(date)

    # process all daily stats for given date
    Jobs::ProcessAllDailyStats.perform_in(600, date) # 10 minutes
  end

  desc "results of api response status yesterday"
  task :display_yesterdays_api_responses do
    require './lib/main'

    date = Date.today - 1
    result = "API responses: #{date.to_s}\n\n"
    responses = Models::ApiResponseStatus.
      where(date: date).
      all.
      group_by { |r| r.url.split('/').last }

    responses.each do |group, group_responses|
      result += "#{group}\n\n"

      group_responses.each do |r|
        emoji = "\xf0\x9f\x9f\xa2" # green circle
        emoji = "\xf0\x9f\x9f\xa1" if r.failure_rate > 2 # yellow circle
        emoji = "\xF0\x9F\x94\xB4" if r.failure_rate > 10 # red circle

        result += "#{emoji} [#{r.failure_count}/#{r.total_count}] #{r.host}\n"
      end

      result += "\n"
    end

    Services::TelegramOperator.notify(
      level: :info,
      message: result
    )
  end

  desc "serialize yesterday's parcel stats"
  task :create_serialized_parcel_stats do
    require './lib/main'

    Jobs::SerializeDailyParcelStats.perform_async(Date.today - 1)
  end

  desc "serialize yesterday's scene stats"
  task :create_serialized_scene_stats do
    require './lib/main'

    Jobs::SerializeDailySceneStats.perform_async(Date.today - 1)
  end

  desc "compile user data"
  task :create_user_data do
    require './lib/main'

    Jobs::ProcessUsers.perform_async(Date.today - 1)
  end

  desc "compile user nft data"
  task :fetch_user_nfts do
    require './lib/main'

    Jobs::ProcessUsersNfts.perform_async
  end
end

namespace :data_preservation do
  # ex: rake data_preservation:daily_parcel_traffic['2022-07-20']
  desc "save enriched peers dump data per day by parcel"
  task :daily_parcel_traffic, [:date] do |task, args|
    require './lib/main'

    date = args[:date] || (Date.today - 1).to_s
    Jobs::ProcessDailyParcelTraffic.perform_async(date)
  end

  # temporary job
  # ex: rake data_preservation:recompile_parcel_traffic['2022-07-20']
  desc "recompile parcel_traffic data"
  task :recompile_parcel_traffic do
    # Don't run this task from midnight to 3am (other tasks are running)
    return if [0, 1, 2].include?(Time.now.utc.hour)

    require './lib/main'

    parsed_parcel_traffic = DATABASE_CONNECTION[
      "select date_trunc('day', date) as day,
      count(id)
      from parcel_traffic
      where date < '2022-11-14'
      and date > '2022-08-21'
      group by day
      order by 1"
    ].all

    parsed_date = parsed_parcel_traffic.last[:day].to_date + 1
    date = parsed_date.to_s

    if parsed_date > Date.parse('2022-11-12')
      Services::TelegramOperator.notify(
        level: :info,
        message: "nearing completion of parcel traffic parsing."
      )
    end

    return if parsed_date > Date.parse('2022-11-14')

    # process parcel_traffic
    Jobs::ProcessDailyParcelTraffic.perform_async(date)
  end

  # temporary job
  # ex: rake data_preservation:recompile_user_activities
  desc "recompile user_activities data from the most recent calculation date"
  task :recompile_user_activities do
    # Don't run this task from midnight to 3am (other tasks are running)
    return if [23, 0, 1, 2].include?(Time.now.utc.hour)

    require './lib/main'

    parsed_user_activities = FAT_BOY_DATABASE[
      "select date_trunc('day', date) as day,
      count(id)
      from user_activities
      where date < '2022-10-06'
      group by day
      order by 1"
    ].all

    parsed_date = parsed_user_activities.last[:day].to_date + 1
    date = parsed_date.to_s
    if parsed_date.month == 10 && parsed_date.day == 6
      Services::TelegramOperator.notify(
        level: :info,
        message: "retroactive User Activity parsing is complete."
      )
    end

    return if date == '2022-10-06'

    # process user activities
    Jobs::ProcessUserActivities.perform_async(date)
  end

  desc "export recent stats to staging db"
  task :export_recent_stats_to_staging_db do
    require './lib/main'

    Jobs::ExportDataToStagingDb.perform_async('daily_stats', 90)
    Jobs::ExportDataToStagingDb.perform_async('daily_parcel_stats', 2)
    Jobs::ExportDataToStagingDb.perform_async('daily_scene_stats', 2)
    Jobs::ExportDataToStagingDb.perform_async('serialized_daily_scene_stats', 1)
    Jobs::ExportDataToStagingDb.perform_async('serialized_daily_parcel_stats', 1)
    Jobs::ExportDataToStagingDb.perform_async('daily_user_stats', 90)

    Jobs::ExportDataToStagingDb.
      perform_async('api_response_status', 14, 'api_response_statuses')
  end
end

namespace :atlas_corp do
  desc "fetch peers"
  task :fetch_peers do
    require './lib/main'

    job_iteration = 600 # time in seconds
    times_to_run  = 10

    times_to_run.times do |i|
      delay = (job_iteration / times_to_run) * i
      Jobs::FetchPeerData.perform_in(delay)
    end
  end
end

namespace :dcl do
  desc "fetch peers"
  task :fetch_peers do
    require './lib/main'

    job_iteration = 600 # time in seconds
    times_to_run  = 10

    times_to_run.times do |i|
      delay = (job_iteration / times_to_run) * i
      Jobs::FetchPeerData.perform_in(delay)
    end
  end

  desc "fetch peer stats"
  task :fetch_peer_stats do
    require './lib/main'

    job_iteration = 600 # time in seconds
    times_to_run  = 10

    times_to_run.times do |i|
      delay = (job_iteration / times_to_run) * i
      Jobs::FetchPeerStats.perform_in(delay)
    end
  end
end

namespace :db do
  APP_NAME = 'dclund'

  desc "Drop database for environment in DATABASE_ENV for DATABASE_USER"
  task :drop do
    unless ENV.member?('DATABASE_ENV')
      raise 'Please provide the environment to create for as `ENV[DATABASE_ENV]`'
    end

    env = ENV['DATABASE_ENV']
    user = ENV['DATABASE_USER']

    `dropdb -U #{user} #{APP_NAME}-#{env}`
    print "Database #{APP_NAME}-#{env} dropped successfully\n"
  end

  desc "Create database for environment in DATABASE_ENV for DATABASE_USER"
  task :create do
    unless ENV.member?('DATABASE_ENV')
      raise 'Please provide the environment to create for as `ENV[DATABASE_ENV]`'
    end

    env = ENV['DATABASE_ENV']
    user = ENV['DATABASE_USER']

    `createdb -p 5432 -U #{user} #{APP_NAME}-#{env}`
    print "Database #{APP_NAME}-#{env} created successfully\n"
  end

  desc "Run migrations (optionally include version number)"
  task :migrate, [:db_url] do |task, args|
    require "sequel"
    Sequel.extension :migration

    # NOTE: example format:
    # DATABASE_URL=postgres://{user}:{password}@{hostname}:{port}/{database-name}

    version = ENV['VERSION']
    database_url = args[:db_url] || ENV['DATABASE_URL']
    unless database_url
      raise 'Please provide a database to run migrations on'
    end

    migration_dir = File.expand_path('../migrations', __FILE__)
    db = Sequel.connect(database_url)

    if version
      puts "Migrating to version #{version}"
      Sequel::Migrator.run(db, migration_dir, :target => version.to_i)
    else
      puts "Running database migrations"
      Sequel::Migrator.run(db, migration_dir)
    end

    puts 'Migration complete'
  end

  desc "Drop, create and migrate DB"
  task :reset do
    return unless %w[development test].include?(ENV['RACK_ENV'])

    Rake::Task["db:drop"].invoke
    Rake::Task["db:create"].invoke
    Rake::Task["db:migrate"].invoke
  end
end
