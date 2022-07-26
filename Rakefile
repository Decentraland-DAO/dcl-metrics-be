# load environment files if running locally
if ENV['RACK_ENV'] == 'test' || ENV['RACK_ENV'] == 'development'
  require 'dotenv'
  Dotenv.load(
    File.expand_path("../.env.#{ENV['RACK_ENV']}", __FILE__),
    File.expand_path('../.env', __FILE__),)
end

task :default => :test
task :test do
  require './spec/spec_helper'
  Dir.glob('./spec/*_spec.rb').each { |file| require file}
end

namespace :heroku do
  desc "run tasks on application release"
  task :release do
    `bundle exec rake db:migrate`
  end
end

# ex: rake compute:all_daily['2022-07-20']
namespace :compute do
  desc "compute all daily stats for date and recalculate for the day previous"
  task :all_daily, [:date] do |task, args|
    require './lib/main'

    date = args[:date] || (Date.today - 1).to_s
    previous_date = (Date.parse(date) - 1).to_s

    # create data points from peers dump
    Services::DailyTrafficCalculator.call(date: date)

    if Models::DataPoint.where(date: previous_date).count.zero?
      Services::DailyTrafficCalculator.call(date: previous_date)
    end

    # build scenes list for date
    Jobs::CreateScenes.perform_in(420, date) # 7 minutes

    # process all user activities for given date
    Jobs::ProcessUserActivities.perform_in(720, date) # 12 minutes

    # rebuild all user activities for previous day
    Jobs::ProcessUserActivities.perform_in(960, previous_date) # 16 minutes

    # process all daily stats for given date
    Jobs::ProcessAllDailyStats.perform_in(1080, date) # 18 minutes

    # process all daily stats for previous day
    Jobs::ProcessAllDailyStats.perform_in(1200, previous_date) # 20 minutes

    # clean up database
    Jobs::CleanUpTransitoryData.perform_in(1320) # 22 minutes
  end

end

namespace :dcl do
  desc "fetch peers"
  task :fetch_peers do
    require './lib/main'

    6.times do |i|
      Jobs::FetchPeerData.perform_in(i * 100)
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
  task :migrate do
    require "sequel"
    Sequel.extension :migration

    # NOTE: example format:
    # DATABASE_URL=postgres://{user}:{password}@{hostname}:{port}/{database-name}
    unless ENV.member?('DATABASE_URL')
      raise 'Please provide a database as `ENV[DATABASE_URL]`'
    end

    version = ENV['VERSION']
    database_url = ENV['DATABASE_URL']
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
