module Jobs
  class ProcessDailyUserStats < Job
    def perform(date)
      # TODO: figure out how to filter users who are more than x% AFK
      time_spent = DATABASE_CONNECTION[
        "select address, sum(duration) AS time_spent
        from user_activities
        where name = 'session'
        and start_time >= '#{date} 00:00:00'
        and start_time <= '#{date} 23:59:00'
        group by address
        order by time_spent desc
        limit 10"
      ].all

      parcels_visited = DATABASE_CONNECTION[
        "select address, count(distinct coordinates) AS parcels_visited
        from data_points
        where date = '#{date}'
        group by address
        order by parcels_visited desc
        limit 10"
      ].all

      # TODO: overnight logins should be counted.
      # 'date' should be the date the event started,
      # for example if a session started yesterday and ended today
      # the date should be yesterday.
      (time_spent + parcels_visited).each do |row|
        Models::DailyUserStats.create(
          date: date,
          address: row[:address],
          time_spent: row[:time_spent],
          parcels_visited: row[:parcels_visited]
        )
      end

      nil
    end
  end
end
