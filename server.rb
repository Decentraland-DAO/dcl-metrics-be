require 'sinatra'

class Server < Sinatra::Application
  ALLOWED_ENDPOINTS = %w[/ /about]

  get '/' do
    "fetched #{Models::PeersDump.count} times"
  end

  post '/api/internal_metrics' do
    request.body.rewind
    data = JSON.parse(request.body.read)
    date = Date.today.to_s
    endpoint = data.delete('endpoint')

    unless ALLOWED_ENDPOINTS.include?(endpoint)
      status 400
      return { msg: "Invalid parameters specified" }.to_json
    end

    # creates potential for RIM Job naming
    Models::RawInternalMetrics.update_or_create(date: date, endpoint: endpoint) do |m|
      existing_metrics = m.metrics_json.nil? ? [] : JSON.parse(m.metrics_json)
      m.metrics_json = existing_metrics.push(data).to_json
    end

    status 201
    {}.to_json
  end

  get '/api/stats' do
    Models::DailyStats.recent.map(&:serialize).to_json
  end

  get '/api/user_stats/:attribute/:sort' do
    attribute = params[:attribute].to_sym

    unless %i[time_spent parcels_visited].include?(attribute)
      status 400
      return { msg: "'#{attribute.to_s}' is not valid." }.to_json
    end

    case params[:sort]
    when 'daily'
      Models::DailyUserStats.
        recent.
        exclude(attribute => nil).
        reverse_order(attribute).
        all.
        group_by { |stats| stats.date.to_s }.
        sort_by(&:first).
        to_h.
        transform_values! { |v| v.map(&:serialize) }.
        to_json
    when 'top'
      result = {}

      Models::DailyUserStats.
        recent.
        exclude(attribute => nil).
        all.
        group_by(&:address).
        each { |address, data| result[address] = data.sum(&attribute) }

      result.sort_by(&:last).reverse.to_h.to_json
    else
      status 400
      return { msg: "Sort parameter '#{params[:sort]}' is not valid." }.to_json
    end
  end

  get '/api/parcel_stats/:attribute/:sort' do
    unless %w[time_spent visitors logins logouts].include?(params[:attribute])
      status 400
      return { msg: "'#{params[:attribute]}' is not valid." }.to_json
    end

    attribute = map_parcel_attribute(params[:attribute])

    case params[:sort]
    when 'daily'
      Models::DailyParcelStats.
        recent.
        exclude(attribute => nil).
        reverse_order(attribute).
        all.
        group_by { |stats| stats.date.to_s }.
        sort_by(&:first).
        to_h.
        transform_values! { |v| v.map(&:serialize) }.
        to_json
    when 'top'
      result = {}

      Models::DailyParcelStats.
        recent.
        exclude(attribute => nil).
        all.
        group_by(&:coordinates).
        each { |c, data| result[c] = sum_parcel_attributes(data, attribute) }

      result.sort_by { |k,v| v[attribute] }.reverse.to_h.to_json
    else
      status 400
      return { msg: "Sort parameter '#{params[:sort]}' is not valid." }.to_json
    end
  end

  private

  def map_parcel_attribute(attribute)
    return :avg_time_spent if attribute == 'time_spent'
    return :unique_visitors if attribute == 'visitors'

    attribute.to_sym
  end

  def sum_parcel_attributes(data, attribute)
    attributes = %i[avg_time_spent avg_time_spent_afk unique_visitors logins logouts]
    result = {}

    attributes.each { |a| result[a] = data.sum { |d| d[a].to_i } }
    result
  end
end
